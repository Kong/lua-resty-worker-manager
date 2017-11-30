# lua-resty-worker-manager


Tracks workers and nodes starting/restarting/reloading/stopping.

## Status

This library is still under early development, and currently lacks tests.

## Synopsis

```nginx
http {
    lua_shared_dict my_shm 5m;

    init_by_lua_block {
        require("resty.worker.manager").on_init_by_lua({
                shm = "my_shm",
                interval = 10,  -- worker heartbeat interval in seconds
                failed = 5, -- max heartbeat overrun to detect crashed worker, in seconds
            },
            function(master_id, n_prev, n_mine, n_next)
                ngx.log(ngx.ERR, "================================= Master start =================================")
                if n_prev == nil then
                    -- no previous master, so this is nginx start or restart
                else
                    -- previous master, so we are reloading
                    if n_prev == 0 then
                        -- all old workers have already exited
                    else
                        -- stil 'n_prev' old workers are running
                    end
                end
            end,
            function(master_id, n_prev, n_mine, n_next)
                ngx.log(ngx.ERR, "================================= Master exit ==================================")
                if n_next == nil then
                    -- we are stopping this nginx node
                else
                    -- we are only reloading, all our workers have already exited, this code
                    -- runs on the last worker.
                    if n_next > 0 then
                        -- new workers have already been initialized
                    end
                end
            end)
        kong = require 'kong'
        kong.init()
    }

    init_worker_by_lua_block {
        require("resty.worker.manager").on_init_worker_by_lua(
            function(worker_id, n_prev, n_mine, n_next)
                ngx.log(ngx.ERR, "--------------------------------- Worker start ---------------------------------")
                if n_mine == 1 then
                    -- I'm the very first worker to start
                elseif n_mine > ngx.worker.count() then
                    -- a worker failed and exited, this a respawned worker.
                    -- After the failed worker heart-beat times out then
                    -- n_mine == ngx.worker.count() again
                else
                    -- other workers have started before me
                end
            end,
            function(worker_id, n_prev, n_mine, n_next)
                ngx.log(ngx.ERR, "--------------------------------- Worker exit ----------------------------------")
                if n_next then
                    -- we are reloading nginx
                end
                if n_mine == 1 then
                    -- I'm the very last worker to exit
                else
                    -- I'm not the last worker, there are more
                end
            end)
        kong.init_worker()
    }
}
```

## Description

Within Nginx/OpenResty it is not always easy to detect workers starting/stopping
and to distinguish between starting/restarting/reloading/stopping the server.
That is what this module does. It detects those, and allows to run synchonized
code (protected within a lock) when it does

See the [online LDoc documentation](http://kong.github.io/lua-resty-worker-manager)
for the complete API.

## History

### 0.1 (xx-Nov-xx) Initial release

  * Initial upload

## Copyright and License

```
Copyright 2017 Kong Inc.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

