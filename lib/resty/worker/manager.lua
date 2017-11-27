--------------------------------------------------------------------------
-- Worker manager.
--
-- This module allows to track nginx workers starting/exiting, as well as
-- detecting Node start/reload/exit.
--
-- All callbacks run within a lock. So while the callback is processing no 
-- other processes can start/stop. They all run _unprotected_ so wrap them in a
-- `pcall` if required.
-- The callbacks all have the same function signature:
--
--   `function(id, n_prev, n_mine, n_next)`
--
-- * `id` is a unique id for the currently starting/stopping worker or master
-- process.
--
-- * `n_prev`: the current number of running workers in the _previous_ master.
--  Will be `nil` if there is no previous master exiting.
--
-- * `n_mine`: the current number of running workers in the master to which the
-- current master or worker belongs.
--
-- * `n_next`: the current number of running workers in the _next_ master (if
-- already started). Will be `nil` if there is no new master starting.
--
-- @copyright 2017 Kong Inc.
-- @author Thijs Schreijer
-- @license Apache 2.0


local pack = function(...) return { n = select("#", ...), ...} end
local _unpack = unpack or table.unpack
local unpack = function(t, i, j) return _unpack(t, i or 1, j or t.n, #t) end
local json_decode = require("cjson").decode
local json_encode = require("cjson").encode

local LOG_PREFIX = "[NODE_TRACKER] "
local SHM_PREFIX = "[NODE_TRACKER] "
local LOCK_KEY = SHM_PREFIX .. "LOCK"
local DATA_KEY = SHM_PREFIX .. "DATA"
local RELOAD_KEY = SHM_PREFIX .. "RELOAD"
local LOCK_AUTORELEASE = 30

local config = {
  shm = nil,
  interval = 10,  -- in seconds
  failed = 5, --in seconds
  master_id = nil, -- ID will be different for each reload
  worker_id = nil, -- ID will be different for each worker(includes master_id)
  worker_exit_cb = nil,
  lock_expires = nil,
  lock_loops = 0,
}

local _M = {}


local function run_locked(cb, ...)
  
  local function get_lock()
    local ok, err
    if config.lock_expires then
      -- we already hold the lock
      if ngx.now() >= config.lock_expires then
        -- it expired on us...
        config.lock_expires = nil
        config.lock_loops = 0
        return nil, "lock expired"
      end
      config.lock_loops = config.lock_loops + 1
    else
      -- we don't have it, so acquire it...
      while not ok do
        ok, err = config.shm:add(LOCK_KEY, true, 5)
        if not ok then
          if err ~= "exists" then return nil, err end
          pcall(ngx.sleep, 0.001) -- if sleep isn't available, we'll do a busy wait
        else
          -- we got the lock
          config.lock_expires = ngx.now() + LOCK_AUTORELEASE - 0.01
          config.lock_loops = 1
        end
      end
    end
    return true
  end

  local function release_lock()
    if not config.lock_expires then
      return nil, "cannot unlock, not holding the lock"
    else
      -- we hold the lock
      if ngx.now() >= config.lock_expires then
        -- it expired on us...
        config.lock_expires = nil
        config.lock_loops = 0
        return nil, "lock expired"
      end
    end
    if config.lock_loops == 1 then
      config.shm:delete(LOCK_KEY)
      config.lock_expires = nil
    end
    config.lock_loops = math.max(0, config.lock_loops - 1)
    return true
  end

  local ok, err = get_lock()
  if not ok then
    ngx.log(ngx.ERR, LOG_PREFIX, "Failed to acquire lock: ", err)
    return nil, err
  else
    ngx.log(ngx.DEBUG, LOG_PREFIX, "acquired lock")
  end

  local results = pack(cb(...))

  ok, err = release_lock()
  if not ok then
    ngx.log(ngx.ERR, LOG_PREFIX, "Failed to release lock: ", err)
    return nil, err
  else
    ngx.log(ngx.DEBUG, LOG_PREFIX, "released lock")
  end

  return unpack(results)

end

-- calls the callback `cb`. The callback gets `data` passed, and the result is stored
-- again as `data`. The callback can return 2 results; `data` and `after_update_cb`. The
-- latter is called after updating `data`, but before releasing the lock.
-- The whole operation will be inside the lock (get/update/set)
-- @return the data as set, or nil+err
local function with_data(cb)
  return run_locked(function()
    local ok, data, err, after_update_cb
    data, err = config.shm:get(DATA_KEY)
    if err then return nil, err end

    if data then
      data = json_decode(data)
    else
      data = {}
    end

    data, after_update_cb = cb(data)
    if not data then return nil, after_update_cb end

    data = json_encode(data)
    ok, err = config.shm:set(DATA_KEY, data)
    if err then return nil, err end

    if after_update_cb then
      after_update_cb()  -- runs after updating, but still within the lock
    end
    return data
  end)
end

--- Initializer.
-- MUST be called in the `init_by_lua` phase. The `opts` table supports the following options:
--
-- * `shm`: (required) name of the shm to use for synchonization
--
-- * `interval`: (optional) heartbeat interval in seconds (default = 10)
--
-- * `failed`: (optional) max heartbeat overrun (in seconds) before a worker is
-- considered crashed (default = 5)
--
-- @param opts Options table
-- @param master_start_cb callback called when the master process starts
-- @param master_exit_cb callback called when the master process exits
-- @return success, err
function _M.on_init_by_lua(opts, master_start_cb, master_exit_cb)
  assert(ngx.get_phase() == "init", "This must be called in the `init_by_lua` phase")
  assert(not config.shm, "Already initialized, only call once")
  config.shm = assert(ngx.shared[opts.shm], "unknown shm `"..tostring(opts.shm).."'")
  config.interval = opts.interval or config.interval
  config.failed = opts.failed or config.failed
  config.worker_exit_cb = nil
  config.master_exit_cb = master_exit_cb

  local n_previous, n_mine, n_next -- # workers in previous/mine/next master

  local data, err = with_data(function(data)
    local err
    config.master_id, err = config.shm:incr(RELOAD_KEY, 1, 0)
    if not config.master_id then return nil, err end
    data[config.master_id] = { n = 0 }

    config.worker_id = nil
    LOG_PREFIX = "[NODE_TRACKER " .. config.master_id .. "] " 

    n_previous = (data[config.master_id - 1] or {}).n
    n_mine = (data[config.master_id] or {}).n
    n_next = (data[config.master_id + 1] or {}).n
    ngx.log(ngx.DEBUG, LOG_PREFIX, "master started #workers; previous: ", n_previous, " mine: ", n_mine, " next: ", n_next)

    return data, function()
                   -- this gets executed after updating `data`, but before releasing the lock
                   if master_start_cb then
                     master_start_cb(config.master_id, n_previous, n_mine, n_next)
                   end
                 end
  end)

  if not data then
    ngx.log(ngx.ERR, LOG_PREFIX, "error starting master: ", err)
    return nil, "Error starting master: " .. tostring(err)
  end

  return true
end


local function worker_exiting()
  local data, err = with_data(function(data)
    local n_previous, n_mine, n_next -- # workers in previous/mine/next master
    n_previous = (data[config.master_id - 1] or {}).n
    n_mine = (data[config.master_id] or {}).n
    n_next = (data[config.master_id + 1] or {}).n
    ngx.log(ngx.DEBUG, LOG_PREFIX, "worker exiting #workers; previous: ", n_previous, " mine: ", n_mine, " next: ", n_next)
    if config.worker_exit_cb then
      config.worker_exit_cb(config.worker_id, n_previous, n_mine, n_next)
    end

    local workers = data[config.master_id]
    workers.n = workers.n - 1
    workers[config.worker_id] = nil

    return data, function()
                   -- this gets executed after updating `data`, but before releasing the lock
                   if n_mine == 1 and config.master_exit_cb then
                     config.master_exit_cb(config.master_id, n_previous, 0, n_next)
                   end
                 end
  end)

  if not data then
    ngx.log(ngx.ERR, LOG_PREFIX, "error exiting worker: ", err)
  end

end


local function timer_cb(premature)
  if premature then
    return worker_exiting()
  end

  local ok, data, err
  -- reschedule timer
  ok, err = ngx.timer.at(config.interval, timer_cb)
  if not ok and err == "process exiting" then
    return worker_exiting()
  end

  ngx.log(ngx.DEBUG, LOG_PREFIX, "heartbeat")

  data, err = with_data(function(data)
    local now = ngx.now()
    -- update my own heartbeat
    if not data[config.master_id][config.worker_id] then
      ngx.log(ngx.ERR, LOG_PREFIX, " worker with id '", config.worker_id, "' recovered from previously missed heartbeat")
      data[config.master_id].n =  data[config.master_id].n + 1
    end
    data[config.master_id][config.worker_id] = now + config.interval + config.failed
    -- validate other heartbeats
    for _, workers in pairs(data) do
      for id, expire in pairs(workers) do
        if id ~= "n" then -- don't track n, as its only our counter
          if expire <= now then
            -- expired, remove it
            ngx.log(ngx.ERR, LOG_PREFIX, " worker with id '", id, "' failed its heartbeat, removing it")
            workers[id] = nil
            workers.n = workers.n - 1
          end
        end
      end
    end

    return data
  end)

  if not data then
    ngx.log(ngx.ERR, LOG_PREFIX, "error running worker heartbeat: ", err)
  end

end

--- Initialize worker.
-- MUST be called in the `init_worker_by_lua` phase.
-- @param start_cb callback called when the worker process starts
-- @param exit_cb callback called when the worker process exits
-- @return success, err
function _M.on_init_worker_by_lua(start_cb, exit_cb)
  assert(ngx.get_phase() == "init_worker", "This must be called in the `init_worker_by_lua` phase")
  assert(config.master_id ~= nil, "You must first call 'on_init_by_lua' to initialize")
  assert(config.worker_id == nil, "This function can only be called once")
  local id = config.master_id .. "-" .. ngx.worker.pid()
  LOG_PREFIX = "[NODE_TRACKER " .. id .. "] "
  local n_previous, n_mine, n_next -- # workers in previous/mine/next master
  config.worker_exit_cb = exit_cb

  local data, err = with_data(function(data)
    -- this runs inside the data-lock
    config.worker_id = id
    
    local workers = data[config.master_id]

    workers.n = workers.n + 1
    workers[config.worker_id] = ngx.now() + config.interval + config.failed  -- heartbeat expires

    n_previous = (data[config.master_id - 1] or {}).n
    n_mine = (data[config.master_id] or {}).n
    n_next = (data[config.master_id + 1] or {}).n
    ngx.log(ngx.DEBUG, LOG_PREFIX, "worker started #workers; previous: ", n_previous, " mine: ", n_mine, " next: ", n_next)

    return data, function()
                   -- this gets executed after updating `data`, but before releasing the lock
                   if start_cb then
                     start_cb(config.worker_id, n_previous, n_mine, n_next)
                   end
                 end
  end)

  if not data then
    ngx.log(ngx.ERR, LOG_PREFIX, "error initializing worker: ", err)
    return nil, "Error starting worker: " .. tostring(err)
  end

  -- here we run outside the data-lock
  ngx.timer.at(config.interval, timer_cb)
  
  return true
end

return _M
