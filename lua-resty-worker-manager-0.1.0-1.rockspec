package = "lua-resty-worker-manager"
version = "0.1.0-1"
source = {
   url = "https://github.com/kong/lua-resty-worker-manager/archive/0.1.0.tar.gz",
   dir = "lua-resty-worker-manager-0.1.0"
}
description = {
   summary = "Worker/Node starting/reloading/stopping tracker for OpenResty",
   detailed = [[
      Track nodes and workers starting, reloading and stopping. To allow for
      singular code to run on node/worker level.
   ]],
   license = "Apache 2.0",
   homepage = "https://github.com/kong/lua-resty-worker-manager"
}
dependencies = {
}
build = {
   type = "builtin",
   modules = { 
     ["resty.worker.manager"] = "lib/resty/worker/manager.lua",
   }
}
