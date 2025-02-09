local async = require('neotest.async')
local Path = require('plenary.path')
local lib = require('neotest.lib')

local api = vim.api
local fn = vim.fn
local fmt = string.format

local test_statuses = {
  -- NOTE: Do these statuses need to be handled
  run = false, -- the test has started running
  pause = false, -- the test has been paused
  cont = false, -- the test has continued running
  bench = false, -- the benchmark printed log output but did not fail
  output = false, -- the test printed output
  --------------------------------------------------
  pass = 'passed', -- the test passed
  fail = 'failed', -- the test or benchmark failed
  skip = 'skipped', -- the test was skipped or the package contained no tests
}

--- Remove newlines from test output
---@param output string
---@return string
local function sanitize_output(output)
  if not output then
    return output
  end
  return output:gsub('\n', ''):gsub('\t', '')
end

local function highlight_output(output)
  if not output then
    return output
  end
  if string.find(output, 'FAIL') then
    output = output:gsub('^', '[31m'):gsub('$', '[0m')
  elseif string.find(output, 'PASS') then
    output = output:gsub('^', '[32m'):gsub('$', '[0m')
  elseif string.find(output, 'SKIP') then
    output = output:gsub('^', '[33m'):gsub('$', '[0m')
  end
  return output
end

-- replace whitespace with underscores and remove surrounding quotes
local function transform_test_name(name)
  return name:gsub('[%s]', '_'):gsub('^"(.*)"$', '%1')
end

---Get a line in a buffer, defaulting to the first if none is specified
---@param buf number
---@param nr number?
---@return string
local function get_buf_line(buf, nr)
  nr = nr or 0
  assert(buf and type(buf) == 'number', 'A buffer is required to get the first line')
  return vim.trim(api.nvim_buf_get_lines(buf, nr, nr + 1, false)[1])
end

---@return string
local function get_build_tags()
  local line = get_buf_line(0)
  local tag_format
  for _, item in ipairs({ '// +build ', '//go:build ' }) do
    if vim.startswith(line, item) then
      tag_format = item
    end
  end
  if not tag_format then
    return ''
  end
  local tags = vim.split(line:gsub(tag_format, ''), ' ')
  if #tags < 1 then
    return ''
  end
  return fmt('-tags=%s', table.concat(tags, ','))
end

local function get_go_package_name(_)
  local line = get_buf_line(0)
  return vim.startswith('package', line) and vim.split(line, ' ')[2] or ''
end

local function get_experimental_opts()
  return {
    test_table = false
  }
end

---Convert the json output from `gotest` to an intermediate format more similar to
---neogit.Result. Collect the progress of each test into a subtable and add a field for
---the final result
---@param lines string[]
---@param output_file string
---@return table, table
local function marshal_gotest_output(lines, output_file)
  local tests = {}
  local log = {}
  for _, line in ipairs(lines) do
    if line ~= '' then
      local ok, parsed = pcall(vim.json.decode, line, { luanil = { object = true } })
      if not ok then
        log = vim.tbl_map(function (l)
          return highlight_output(l)
        end, lines)
        return tests, log
      end
      local output = highlight_output(sanitize_output(parsed.Output))
      if output then
        table.insert(log, output)
      end
      local action, name = parsed.Action, parsed.Test
      if name then
        local status = test_statuses[action]
        -- sub-tests are structured as 'TestMainTest/subtest_clause'
        local parts = vim.split(name, '/')
        local is_subtest = #parts > 1
        local parent = is_subtest and parts[1] or nil
        if not tests[name] then
          tests[name] = {
            output = {},
            progress = {},
            output_file = output_file,
          }
        end
        table.insert(tests[name].progress, action)
        if status then
          tests[name].status = status
        end
        if output then
          table.insert(tests[name].output, output)
          if parent then
            table.insert(tests[parent].output, output)
          end
        end
      end
    end
  end
  return tests, log
end

---@type neotest.Adapter
local adapter = { name = 'neotest-go' }

adapter.root = lib.files.match_root_pattern('go.mod', 'go.sum')

function adapter.is_test_file(file_path)
  if not vim.endswith(file_path, '.go') then
    return false
  end
  local elems = vim.split(file_path, Path.path.sep)
  local file_name = elems[#elems]
  local is_test = vim.endswith(file_name, '_test.go')
  return is_test
end

---@param position neotest.Position The position to return an ID for
---@param namespaces neotest.Position[] Any namespaces the position is within
local function generate_position_id(position, namespaces)
  local prefix = {}
  for _, namespace in ipairs(namespaces) do
    if namespace.type ~= 'file' then
      table.insert(prefix, namespace.name)
    end
  end
  local name = transform_test_name(position.name)
  return table.concat(vim.tbl_flatten({ position.path, prefix, name }), '::')
end

---@async
---@return neotest.Tree| nil
function adapter.discover_positions(path)
  local query = [[
    ((function_declaration
      name: (identifier) @test.name)
      (#match? @test.name "^(Test|Example)"))
      @test.definition

    (method_declaration
      name: (field_identifier) @test.name
      (#match? @test.name "^(Test|Example)")) @test.definition

    (call_expression
      function: (selector_expression
        field: (field_identifier) @test.method)
        (#match? @test.method "^Run$")
      arguments: (argument_list . (interpreted_string_literal) @test.name))
      @test.definition
  ]]

  if get_experimental_opts().test_table then
    query = query .. [[

    (block
      (short_var_declaration
        left: (expression_list
          (identifier) @test.cases)
        right: (expression_list
          (composite_literal
            (literal_value
              (literal_element
                (literal_value
                  (keyed_element
                    (literal_element
                      (identifier) @test.field.name)
                    (literal_element
                      (interpreted_string_literal) @test.name)))) @test.definition))))
      (for_statement
        (range_clause
          left: (expression_list
            (identifier) @test.case)
          right: (identifier) @test.cases1
            (#eq? @test.cases @test.cases1))
        body: (block
          (call_expression
            function: (selector_expression
              field: (field_identifier) @test.method)
              (#match? @test.method "^Run$")
            arguments: (argument_list
              (selector_expression
                operand: (identifier) @test.case1
                (#eq? @test.case @test.case1)
                field: (field_identifier) @test.field.name1
                (#eq? @test.field.name @test.field.name1)))))))
    ]]
  end

  return lib.treesitter.parse_positions(path, query, {
    require_namespaces = false,
    nested_tests = true,
    position_id = generate_position_id,
  })
end

---@param tree neotest.Tree
---@param name string
---@return string
local function get_prefix(tree, name)
  local parent_tree = tree:parent()
  if not parent_tree or parent_tree:data().type == 'file' then
    return name
  end
  local parent_name = parent_tree:data().name
  return parent_name .. '/' .. name
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function adapter.build_spec(args)
  local results_path = async.fn.tempname()
  local position = args.tree:data()
  local dir = position.path
  -- The path for the position is not a directory, ensure the directory variable refers to one
  if fn.isdirectory(position.path) ~= 1 then
    dir = fn.fnamemodify(position.path, ':h')
  end
  local package = get_go_package_name(position.path)

  local cmd_args = ({
    dir = { dir .. '/...' },
    -- file is the same as dir because running a single test file
    -- fails if it has external dependencies
    file = { dir .. '/...' },
    namespace = { package },
    test = { '-run', get_prefix(args.tree, position.name) .. '\\$', dir },
  })[position.type]

  local command = vim.tbl_flatten({
    'go',
    'test',
    '-v',
    '-json',
    get_build_tags(),
    args.extra_args or {},
    unpack(cmd_args),
  })

  return {
    command = table.concat(command, ' '),
    context = {
      results_path = results_path,
      file = position.path,
    },
  }
end

---@async
---@param _ neotest.RunSpec
---@param result neotest.StrategyResult
---@param tree neotest.Tree
---@return table<string, neotest.Result[]>
function adapter.results(_, result, tree)
  local success, data = pcall(lib.files.read, result.output)
  if not success then
    return {}
  end
  local lines = vim.split(data, '\r\n')
  local tests, log = marshal_gotest_output(lines, result.output)
  local results = {}
  local no_results = vim.tbl_isempty(tests)
  local empty_result_fname
  if no_results then
    empty_result_fname = async.fn.tempname()
    fn.writefile(log, empty_result_fname)
  end
  for _, node in tree:iter_nodes() do
    local value = node:data()
    if no_results then
      results[value.id] = {
        status = test_statuses.fail,
        output = empty_result_fname,
      }
    else
      local id_parts = vim.split(value.id, '::')
      table.remove(id_parts, 1)
      local test_output = tests[table.concat(id_parts, '/')]
      if test_output then
        local fname = async.fn.tempname()
        fn.writefile(test_output.output, fname)
        results[value.id] = {
          status = test_output.status,
          short = table.concat(test_output.output, '\n'),
          output = fname,
        }
      end
    end
  end
  return results
end

local is_callable = function(obj)
  return type(obj) == 'function' or (type(obj) == 'table' and obj.__call)
end

setmetatable(adapter, {
  __call = function(_, opts)
    if is_callable(opts.experimental) then
      get_experimental_opts = opts.experimental
    elseif opts.experimental then
      get_experimental_opts = function()
        return opts.experimental
      end
    end

    return adapter
  end,
})

return adapter
