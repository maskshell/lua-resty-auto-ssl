-- Ensure resty.core FFI libraries are loaded to prevent potential deadlocks in
-- shdict. These are loaded by default in OpenResty 1.15.8.1+, but this will
-- ensure this library is loaded in older versions.
--
-- https://github.com/openresty/lua-nginx-module/issues/1207#issuecomment-350742782
-- https://github.com/auto-ssl/lua-resty-auto-ssl/issues/43
-- https://github.com/auto-ssl/lua-resty-auto-ssl/issues/220
require "resty.core"

-- Resolve the root directory that the scripts and binaries are historically
-- installed under (like "/usr/local" for luarocks installs). This only
-- matches module paths with at least 5 slashes (like
-- "/usr/local/lib/lua/5.1/resty/auto-ssl.lua") and returns nil for shallower
-- layouts (like "lib/resty/auto-ssl.lua" from a git checkout or an opm --cwd
-- install).
--
-- This is intentionally computed lazily on first use (via the "__index"
-- handler on the module table below), since running this at require time
-- would crash on those shallower layouts.
local function compute_lua_root()
  local current_file_path = package.searchpath("resty.auto-ssl", package.path)
  if not current_file_path then
    return nil
  end

  local lua_root = string.match(current_file_path, "(.*)/.*/.*/.*/.*/.*")
  if lua_root and string.sub(lua_root, 1, 2) == "./" then
    local lfs = require "lfs"
    lua_root = lfs.currentdir() .. string.sub(lua_root, 2, -1)
  end

  return lua_root
end

local _M = setmetatable({}, {
  __index = function(module, key)
    -- The "lua_root" field is kept for backwards compatibility, but it's now
    -- computed lazily on first access (and then cached on the module table),
    -- so requiring this module no longer crashes on shallow "package.path"
    -- layouts where the match above returns nil.
    if key == "lua_root" then
      local lua_root = compute_lua_root()
      if lua_root then
        rawset(module, "lua_root", lua_root)
      end
      return lua_root
    end

    return nil
  end,
})

-- Module-level mirror of the instance "bin_dir" option. It exists ONLY for
-- callers that hold the module table itself (utils/start_sockproc resolves
-- "start_sockproc" without an instance) — sockproc is a process-global
-- daemon, so a process-global fallback for that resolution path matches
-- reality. Instance-level rule 1 NEVER reads this mirror: an instance that
-- did not set "bin_dir" falls through to rules 2/3 like normal. The mirror
-- reflects the most recently created or configured instance (new() resets
-- it, including to nil).
local bin_dir_override = nil

function _M.new(options)
  if not options then
    options = {}
  end

  if not options["dir"] then
    options["dir"] = "/etc/resty-auto-ssl"
  end

  if not options["request_domain"] then
    options["request_domain"] = function(ssl, ssl_options) -- luacheck: ignore
      return ssl.server_name()
    end
  end

  if not options["allow_domain"] then
    options["allow_domain"] = function(domain, auto_ssl, ssl_options, renewal) -- luacheck: ignore
      return false
    end
  end

  if not options["storage_adapter"] then
    options["storage_adapter"] = "resty.auto-ssl.storage_adapters.file"
  end

  if not options["json_adapter"] then
    options["json_adapter"] = "resty.auto-ssl.json_adapters.cjson"
  end

  if not options["ocsp_stapling_error_level"] then
    options["ocsp_stapling_error_level"] = ngx.ERR
  end

  if not options["renew_check_interval"] then
    options["renew_check_interval"] = 86400 -- 1 day
  end

  if not options["hook_server_port"] then
    options["hook_server_port"] = 8999
  end

  bin_dir_override = options["bin_dir"]

  return setmetatable({ options = options }, { __index = _M })
end

function _M.set(self, key, value)
  if key == "storage" then
    ngx.log(ngx.ERR, "auto-ssl: DEPRECATED: Don't use auto_ssl:set() for the 'storage' instance. Set directly with auto_ssl.storage.")
    self.storage = value
    return
  end

  if key == "bin_dir" then
    bin_dir_override = value
  end

  self.options[key] = value
end

function _M.get(self, key)
  if key == "storage" then
    ngx.log(ngx.ERR, "auto-ssl: DEPRECATED: Don't use auto_ssl:get() for the 'storage' instance. Get directly with auto_ssl.storage.")
    return self.storage
  end

  return self.options[key]
end

-- Resolve the full path to one of the external scripts that this module
-- shells out to ("dehydrated", "letsencrypt_hooks", or "start_sockproc").
-- Note that "sockproc" itself is resolved by the "start_sockproc" script
-- relative to its own location, so it is never resolved from Lua here.
--
-- Paths are resolved in this order:
--   1. The "bin_dir" option, if it's been explicitly set.
--   2. A "bin/resty-auto-ssl/" directory adjacent to this module (like the
--      bin assets from a GitHub release installed next to an opm install).
--   3. The legacy "lua_root"-based location (like
--      "/usr/local/bin/resty-auto-ssl/" for luarocks installs).
--
-- Returns nil if no path could be resolved.
function _M.get_bin(self, name)
  -- Tolerate the dot-call convenience: get_bin("dehydrated") without an
  -- explicit self resolves against the module table.
  if type(self) ~= "table" then
    self, name = _M, self
  end

  -- Rule 1 is strictly per-instance: an instance that never set "bin_dir"
  -- never inherits another instance's override. The module-level mirror is
  -- consulted only when called on the module table itself (see the
  -- "bin_dir_override" declaration above for why that path exists).
  if self.options and self.options["bin_dir"] then
    return self.options["bin_dir"] .. "/" .. name
  end
  if self == _M and bin_dir_override then
    return bin_dir_override .. "/" .. name
  end

  -- Check for a "bin/resty-auto-ssl/" directory installed adjacent to the
  -- "auto-ssl" module directory itself. Relative searchpaths (like from opm
  -- --cwd installs) are absolutized, since the resolved paths are passed to
  -- shell commands that may be running in a different working directory.
  local current_file_path = package.searchpath("resty.auto-ssl", package.path)
  if current_file_path then
    local module_dir = string.match(current_file_path, "(.*)/auto%-ssl%.lua$")
    if module_dir then
      if string.sub(module_dir, 1, 2) == "./" then
        local lfs = require "lfs"
        module_dir = lfs.currentdir() .. string.sub(module_dir, 2, -1)
      end

      local path = module_dir .. "/auto-ssl/bin/resty-auto-ssl/" .. name
      local file = io.open(path, "r")
      if file then
        -- io.open also succeeds for directories (and a FIFO would block it);
        -- a zero-length read fails on directories, weeding out the common
        -- misdetection without widening the lfs dependency. It also rejects
        -- empty files on some platforms — acceptable, since an empty bin
        -- script is broken anyway.
        local readable = file:read(0)
        file:close()
        if readable then
          return path
        end
      end
    end
  end

  -- Fall back to the legacy "lua_root"-based location. Reading the
  -- "lua_root" field lazily computes and caches it, if it hasn't been
  -- resolved yet.
  local lua_root = self.lua_root
  if lua_root then
    return lua_root .. "/bin/resty-auto-ssl/" .. name
  end

  return nil
end

function _M.init(self)
  local init_master = require "resty.auto-ssl.init_master"
  init_master(self)
end

function _M.init_worker(self)
  local init_worker = require "resty.auto-ssl.init_worker"
  init_worker(self)
end

function _M.ssl_certificate(self, ssl_options)
  local ssl_certificate = require "resty.auto-ssl.ssl_certificate"
  ssl_certificate(self, ssl_options)
end

function _M.challenge_server(self)
  local server = require "resty.auto-ssl.servers.challenge"
  server(self)
end

function _M.has_certificate(self, domain, shmem_only)
  local has_certificate = require "resty.auto-ssl.utils.has_certificate"
  return has_certificate(self, domain, shmem_only)
end

function _M.hook_server(self)
  local server = require "resty.auto-ssl.servers.hook"
  server(self)
end

return _M
