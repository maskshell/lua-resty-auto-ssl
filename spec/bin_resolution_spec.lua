-- "lfs" (luafilesystem) is a transitive test-tree dependency (via penlight).
-- The popen fallback below covers this spec's own cwd needs on minimal busted
-- installs; the module's "./"-path absolutization branch (exercised by the
-- relative-path tests) still hard-requires lfs in the interpreter, matching
-- upstream behavior.
local has_lfs, lfs = pcall(require, "lfs")
local currentdir
if has_lfs then
  currentdir = function()
    return lfs.currentdir()
  end
else
  currentdir = function()
    local pipe = assert(io.popen("pwd"))
    local cwd = string.gsub(pipe:read("*a"), "\n+$", "")
    pipe:close()
    return cwd
  end
end

-- This spec is unit-level and only exercises path resolution, so it can also
-- run outside of OpenResty (like with a plain busted install). The module
-- requires "resty.core" on load for nginx shdict safety, but never touches
-- the nginx FFI APIs during path resolution, so stub it out when it's not
-- available.
if not pcall(require, "resty.core") then
  package.loaded["resty.core"] = {}
end

-- Provide a minimal "ngx" stub when running outside of OpenResty, since
-- auto_ssl.new() reads "ngx.ERR" while filling in its option defaults.
if not ngx then
  _G.ngx = { ERR = 4 }
end

-- Fixture scaffolding is kept dependency-free (no penlight), so the spec can
-- run both inside OpenResty and under a plain busted interpreter. Fixtures
-- live under "spec/tmp/", which is already used for runtime test data.
local fixture_counter = 0
local created_roots = {}

local function new_fixture_root()
  fixture_counter = fixture_counter + 1
  local root = currentdir() .. "/spec/tmp/bin-resolution/fixture-" .. fixture_counter
  created_roots[#created_roots + 1] = root
  return root
end

local function makepath(path)
  os.execute("mkdir -p '" .. path .. "'")
end

local function rmtree(path)
  os.execute("rm -rf '" .. path .. "'")
end

-- Fixture bin files carry minimal content (not zero bytes), matching real
-- scripts: the module's rule-2 existence probe reads a byte to reject
-- directories, and an empty file would be rejected by that same probe.
local function touch(path)
  local file = assert(io.open(path, "w"))
  file:write("#!/bin/sh\n")
  file:close()
end

local function copy_auto_ssl_module(dest_path)
  local source = assert(io.open(currentdir() .. "/lib/resty/auto-ssl.lua", "r"))
  local content = source:read("*a")
  source:close()

  local dest = assert(io.open(dest_path, "w"))
  dest:write(content)
  dest:close()
end

-- Turns an absolute path under the current working directory into a relative
-- one (like the searchpaths that opm --cwd installs produce).
local function relative_to_cwd(path)
  local cwd = currentdir()
  if string.sub(path, 1, #cwd + 1) == cwd .. "/" then
    return "./" .. string.sub(path, #cwd + 2)
  end

  return path
end

-- Replicates the luarocks install layout, where the module lives at
-- "<root>/usr/local/lib/lua/5.1/resty/auto-ssl.lua" and the bin payload is
-- installed at "<root>/usr/local/bin/resty-auto-ssl/".
local function make_luarocks_fixture()
  local root = new_fixture_root()
  makepath(root .. "/usr/local/lib/lua/5.1/resty")
  makepath(root .. "/usr/local/bin/resty-auto-ssl")
  copy_auto_ssl_module(root .. "/usr/local/lib/lua/5.1/resty/auto-ssl.lua")
  touch(root .. "/usr/local/bin/resty-auto-ssl/dehydrated")
  touch(root .. "/usr/local/bin/resty-auto-ssl/letsencrypt_hooks")
  touch(root .. "/usr/local/bin/resty-auto-ssl/start_sockproc")
  return root
end

-- Replicates the opm install + bin asset layout, where the module lives at
-- "<root>/resty/auto-ssl.lua" and the bin payload is installed at
-- "<root>/resty/auto-ssl/bin/resty-auto-ssl/".
local function make_module_adjacent_fixture()
  local root = new_fixture_root()
  makepath(root .. "/resty/auto-ssl/bin/resty-auto-ssl")
  copy_auto_ssl_module(root .. "/resty/auto-ssl.lua")
  touch(root .. "/resty/auto-ssl/bin/resty-auto-ssl/dehydrated")
  touch(root .. "/resty/auto-ssl/bin/resty-auto-ssl/letsencrypt_hooks")
  touch(root .. "/resty/auto-ssl/bin/resty-auto-ssl/start_sockproc")
  return root
end

describe("bin resolution", function()
  local orig_package_path

  local function reload_auto_ssl(path_entry)
    package.path = path_entry
    package.loaded["resty.auto-ssl"] = nil
    return require "resty.auto-ssl"
  end

  before_each(function()
    orig_package_path = package.path
  end)

  after_each(function()
    package.path = orig_package_path
    package.loaded["resty.auto-ssl"] = nil
    -- Remove every fixture actually created during the test (helpers allocate
    -- roots lazily, so before_each cannot know them up front).
    for _, root in ipairs(created_roots) do
      rmtree(root)
    end
    for i = #created_roots, 1, -1 do
      created_roots[i] = nil
    end
  end)

  it("uses the bin_dir option when it's explicitly set", function()
    local module_dir = make_module_adjacent_fixture()
    local auto_ssl = reload_auto_ssl(module_dir .. "/?.lua")

    local instance = auto_ssl.new()
    instance:set("bin_dir", "/opt/resty-auto-ssl-custom-bins")

    assert.equal("/opt/resty-auto-ssl-custom-bins/dehydrated", instance:get_bin("dehydrated"))
    assert.equal("/opt/resty-auto-ssl-custom-bins/letsencrypt_hooks", instance:get_bin("letsencrypt_hooks"))
    assert.equal("/opt/resty-auto-ssl-custom-bins/start_sockproc", instance:get_bin("start_sockproc"))
  end)

  it("mirrors an instance-set bin_dir to the module table", function()
    -- "start_sockproc" is resolved from the module table (without an
    -- instance), so an instance-set "bin_dir" must be visible there too.
    local module_dir = make_module_adjacent_fixture()
    local auto_ssl = reload_auto_ssl(module_dir .. "/?.lua")

    local instance = auto_ssl.new()
    instance:set("bin_dir", "/opt/resty-auto-ssl-custom-bins")

    assert.equal("/opt/resty-auto-ssl-custom-bins/start_sockproc", auto_ssl.get_bin(auto_ssl, "start_sockproc"))
    assert.equal("/opt/resty-auto-ssl-custom-bins/dehydrated", auto_ssl.get_bin(auto_ssl, "dehydrated"))
  end)

  it("does not leak an instance bin_dir into other instances", function()
    local module_dir = make_module_adjacent_fixture()
    local auto_ssl = reload_auto_ssl(module_dir .. "/?.lua")

    local configured = auto_ssl.new()
    configured:set("bin_dir", "/opt/resty-auto-ssl-custom-bins")

    -- An instance created later without "bin_dir" must fall through to the
    -- normal rules (module-adjacent here), never inherit the override.
    local plain = auto_ssl.new()
    local bin_dir = module_dir .. "/resty/auto-ssl/bin/resty-auto-ssl"
    assert.equal(bin_dir .. "/dehydrated", plain:get_bin("dehydrated"))
    assert.equal(bin_dir .. "/start_sockproc", plain:get_bin("start_sockproc"))
  end)

  it("resolves binaries adjacent to the module package for absolute package paths", function()
    local module_dir = make_module_adjacent_fixture()
    local auto_ssl = reload_auto_ssl(module_dir .. "/?.lua")

    local instance = auto_ssl.new()
    local bin_dir = module_dir .. "/resty/auto-ssl/bin/resty-auto-ssl"
    assert.equal(bin_dir .. "/dehydrated", instance:get_bin("dehydrated"))
    assert.equal(bin_dir .. "/letsencrypt_hooks", instance:get_bin("letsencrypt_hooks"))
    assert.equal(bin_dir .. "/start_sockproc", instance:get_bin("start_sockproc"))
  end)

  it("absolutizes relative module package paths", function()
    local module_dir = make_module_adjacent_fixture()
    -- Use a relative package.path entry (like opm --cwd installs yield), so
    -- the resolved paths must be absolutized to match the fixture location.
    local auto_ssl = reload_auto_ssl(relative_to_cwd(module_dir) .. "/?.lua")

    local instance = auto_ssl.new()
    local bin_dir = module_dir .. "/resty/auto-ssl/bin/resty-auto-ssl"
    assert.equal(bin_dir .. "/dehydrated", instance:get_bin("dehydrated"))
    assert.equal(bin_dir .. "/letsencrypt_hooks", instance:get_bin("letsencrypt_hooks"))
    assert.equal(bin_dir .. "/start_sockproc", instance:get_bin("start_sockproc"))
  end)

  it("falls back to the legacy lua_root-based path when no module-adjacent bins exist", function()
    local luadir = make_luarocks_fixture()
    local auto_ssl = reload_auto_ssl(relative_to_cwd(luadir) .. "/usr/local/lib/lua/5.1/?.lua")

    local instance = auto_ssl.new()
    assert.equal(luadir .. "/usr/local", instance.lua_root)

    local bin_dir = luadir .. "/usr/local/bin/resty-auto-ssl"
    assert.equal(bin_dir .. "/dehydrated", instance:get_bin("dehydrated"))
    assert.equal(bin_dir .. "/letsencrypt_hooks", instance:get_bin("letsencrypt_hooks"))
    assert.equal(bin_dir .. "/start_sockproc", instance:get_bin("start_sockproc"))
  end)

  it("prefers module-adjacent binaries over the legacy lua_root-based path", function()
    local luadir = make_luarocks_fixture()
    -- Also install the bin payload adjacent to the module itself.
    makepath(luadir .. "/usr/local/lib/lua/5.1/resty/auto-ssl/bin/resty-auto-ssl")
    touch(luadir .. "/usr/local/lib/lua/5.1/resty/auto-ssl/bin/resty-auto-ssl/dehydrated")
    touch(luadir .. "/usr/local/lib/lua/5.1/resty/auto-ssl/bin/resty-auto-ssl/letsencrypt_hooks")

    local auto_ssl = reload_auto_ssl(relative_to_cwd(luadir) .. "/usr/local/lib/lua/5.1/?.lua")

    local instance = auto_ssl.new()
    local adjacent_dir = luadir .. "/usr/local/lib/lua/5.1/resty/auto-ssl/bin/resty-auto-ssl"
    assert.equal(adjacent_dir .. "/dehydrated", instance:get_bin("dehydrated"))
    assert.equal(adjacent_dir .. "/letsencrypt_hooks", instance:get_bin("letsencrypt_hooks"))

    -- start_sockproc only exists in the legacy location, so it still resolves
    -- through the legacy path (resolution happens per file).
    assert.equal(luadir .. "/usr/local/bin/resty-auto-ssl/start_sockproc", instance:get_bin("start_sockproc"))
  end)

  it("does not crash on shallow package paths and leaves lua_root nil", function()
    -- Requiring straight out of a git checkout ("lib/resty/auto-ssl.lua") or
    -- from an opm --cwd install has fewer than 5 slashes in the module path,
    -- which previously crashed at require time with "bad argument #1 to
    -- 'sub'".
    local auto_ssl = reload_auto_ssl("./lib/?.lua")

    assert.Nil(auto_ssl.lua_root)
    assert.Nil(auto_ssl.get_bin(auto_ssl, "dehydrated"))
  end)

  it("resolves paths when called on the module table itself", function()
    -- The utils/start_sockproc module only holds the module table (not an
    -- instance), so resolution from the module table without any options must
    -- still work.
    local module_dir = make_module_adjacent_fixture()
    local auto_ssl = reload_auto_ssl(relative_to_cwd(module_dir) .. "/?.lua")

    assert.equal(module_dir .. "/resty/auto-ssl/bin/resty-auto-ssl/start_sockproc", auto_ssl.get_bin(auto_ssl, "start_sockproc"))
  end)
end)
