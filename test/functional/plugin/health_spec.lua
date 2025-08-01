local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local clear = n.clear
local curbuf_contents = n.curbuf_contents
local command = n.command
local eq, matches = t.eq, t.matches
local getcompletion = n.fn.getcompletion
local insert = n.insert
local exec_lua = n.exec_lua
local source = n.source
local assert_alive = n.assert_alive
local fn = n.fn
local api = n.api

describe(':checkhealth', function()
  it('detects invalid $VIMRUNTIME', function()
    clear({
      env = { VIMRUNTIME = 'bogus' },
    })
    local status, err = pcall(command, 'checkhealth')
    eq(false, status)
    eq('Invalid $VIMRUNTIME: bogus', string.match(err, 'Invalid.*'))
  end)

  it("detects invalid 'runtimepath'", function()
    clear()
    command('set runtimepath=bogus')
    local status, err = pcall(command, 'checkhealth')
    eq(false, status)
    eq("Invalid 'runtimepath'", string.match(err, 'Invalid.*'))
  end)

  it('detects invalid $VIM', function()
    clear()
    -- Do this after startup, otherwise it just breaks $VIMRUNTIME.
    command("let $VIM='zub'")
    command('checkhealth vim.health')
    matches('ERROR $VIM .* zub', curbuf_contents())
  end)

  it('getcompletion()', function()
    clear { args = { '-u', 'NORC', '+set runtimepath+=test/functional/fixtures' } }

    eq('vim.deprecated', getcompletion('vim', 'checkhealth')[1])
    eq('vim.provider', getcompletion('vim.prov', 'checkhealth')[1])
    eq('vim.lsp', getcompletion('vim.ls', 'checkhealth')[1])

    -- "test_plug/health/init.lua" should complete as "test_plug", not "test_plug.health". #30342
    eq({
      'test_plug',
      'test_plug.full_render',
      'test_plug.submodule',
      'test_plug.submodule_empty',
      'test_plug.success1',
      'test_plug.success2',
    }, getcompletion('test_plug', 'checkhealth'))
  end)

  it('completion checks for vim.health._complete() return type #28456', function()
    clear()
    exec_lua([[vim.health._complete = function() return 1 end]])
    eq({}, getcompletion('', 'checkhealth'))
    exec_lua([[vim.health._complete = function() return { 1 } end]])
    eq({}, getcompletion('', 'checkhealth'))
    assert_alive()
  end)

  it('cmdline completion works with multiple args #35054', function()
    clear()
    n.feed(':checkhealth vim.ls<Tab>')
    eq('checkhealth vim.lsp', fn.getcmdline())
    n.feed(' vim.prov<Tab>')
    eq('checkhealth vim.lsp vim.provider', fn.getcmdline())
  end)

  it('vim.g.health', function()
    clear {
      args_rm = { '-u' },
      args = { '--clean', '+set runtimepath+=test/functional/fixtures' },
    }
    command("let g:health = {'style':'float'}")
    command('checkhealth lsp')
    eq(
      'editor',
      exec_lua([[
      return vim.api.nvim_win_get_config(0).relative
    ]])
    )

    -- gO should not close the :checkhealth floating window. #34784
    command('checkhealth full_render')
    local win = api.nvim_get_current_win()
    api.nvim_win_set_cursor(win, { 5, 1 })
    n.feed('gO')
    eq(true, api.nvim_win_is_valid(win))
    eq('qf', api.nvim_get_option_value('filetype', { buf = 0 }))
  end)

  it("vim.provider works with a misconfigured 'shell'", function()
    clear()
    command([[set shell=echo\ WRONG!!!]])
    command('let g:loaded_perl_provider = 0')
    command('let g:loaded_python3_provider = 0')
    command('checkhealth vim.provider')
    eq(nil, string.match(curbuf_contents(), 'WRONG!!!'))
  end)
end)

describe('vim.health', function()
  before_each(function()
    clear { args = { '-u', 'NORC', '+set runtimepath+=test/functional/fixtures' } }
  end)

  describe(':checkhealth', function()
    it('report_xx() renders correctly', function()
      command('checkhealth full_render')
      n.expect([[

      ==============================================================================
      test_plug.full_render:                                              1 ⚠️  1 ❌

      report 1 ~
      - ✅ OK life is fine
      - ⚠️ WARNING no what installed
        - ADVICE:
          - pip what
          - make what

      report 2 ~
      - stuff is stable
      - ❌ ERROR why no hardcopy
        - ADVICE:
          - :help |:hardcopy|
          - :help |:TOhtml|
      ]])
    end)

    it('user FileType handler can modify report', function()
      -- Define a FileType autocmd that removes emoji chars.
      source [[
        autocmd FileType checkhealth :set modifiable | silent! %s/\v( ?[^\x00-\x7F])//g
        checkhealth full_render
      ]]
      n.expect([[

      ==============================================================================
      test_plug.full_render:                                              1  1

      report 1 ~
      - OK life is fine
      - WARNING no what installed
        - ADVICE:
          - pip what
          - make what

      report 2 ~
      - stuff is stable
      - ERROR why no hardcopy
        - ADVICE:
          - :help |:hardcopy|
          - :help |:TOhtml|
      ]])
    end)

    it('concatenates multiple reports', function()
      command('checkhealth success1 success2 test_plug')
      n.expect([[

        ==============================================================================
        test_plug:                                                                  ✅

        report 1 ~
        - ✅ OK everything is fine

        report 2 ~
        - ✅ OK nothing to see here

        ==============================================================================
        test_plug.success1:                                                         ✅

        report 1 ~
        - ✅ OK everything is fine

        report 2 ~
        - ✅ OK nothing to see here

        ==============================================================================
        test_plug.success2:                                                         ✅

        another 1 ~
        - ✅ OK ok
        ]])
    end)

    it('lua plugins submodules', function()
      command('checkhealth test_plug.submodule')
      n.expect([[

        ==============================================================================
        test_plug.submodule:                                                        ✅

        report 1 ~
        - ✅ OK everything is fine

        report 2 ~
        - ✅ OK nothing to see here
        ]])
    end)

    it('... including empty reports', function()
      command('checkhealth test_plug.submodule_empty')
      n.expect([[

      ==============================================================================
      test_plug.submodule_empty:                                                1 ❌

      - ❌ ERROR The healthcheck report for "test_plug.submodule_empty" plugin is empty.
      ]])
    end)

    it('highlights OK, ERROR', function()
      local screen = Screen.new(50, 12)
      screen:set_default_attr_ids({
        h1 = { reverse = true },
        h2 = { foreground = tonumber('0x6a0dad') },
        Ok = { foreground = Screen.colors.LightGreen },
        Error = { foreground = Screen.colors.Red },
        Bar = { foreground = Screen.colors.LightGrey, background = Screen.colors.DarkGrey },
      })
      command('checkhealth foo success1')
      command('set nofoldenable nowrap laststatus=0')
      screen:expect {
        grid = [[
        ^                                                  |
        {Bar:                                                  }|
        {h1:foo:                                              }|
                                                          |
        - ❌ {Error:ERROR} No healthcheck found for "foo" plugin. |
                                                          |
        {Bar:                                                  }|
        {h1:test_plug.success1:                               }|
                                                          |
        {h2:report 1}                                          |
        - ✅ {Ok:OK} everything is fine                        |
                                                          |
      ]],
      }
    end)

    it('gracefully handles invalid healthcheck', function()
      command('checkhealth non_existent_healthcheck')
      -- luacheck: ignore 613
      n.expect([[

        ==============================================================================
        non_existent_healthcheck:                                                 1 ❌

        - ❌ ERROR No healthcheck found for "non_existent_healthcheck" plugin.
        ]])
    end)

    it('does not use vim.health as a healthcheck', function()
      -- vim.health is not a healthcheck
      command('checkhealth vim')
      n.expect([[
      ERROR: No healthchecks found.]])
    end)

    it('nested lua/ directory', function()
      command('checkhealth lua')
      n.expect([[

      ==============================================================================
      test_plug.lua:                                                              ✅

      nested lua/ directory ~
      - ✅ OK everything is ok
      ]])
    end)

    it('&rtp can contain nested path (by packadd)', function()
      -- re-add to ensure this appears before new nested rtp
      command([[set runtimepath-=test/functional/fixtures]])
      command([[set runtimepath+=test/functional/fixtures]])
      command('set packpath+=test/functional/fixtures')
      -- set rtp+=test/functional/fixtures/pack/foo/opt/healthy
      command('packadd healthy')
      command('checkhealth nest')
      n.expect([[

      ==============================================================================
      nest:                                                                       ✅

      healthy pack ~
      - ✅ OK healthy ok
      ]])
    end)
  end)
end)

describe(':checkhealth window', function()
  before_each(function()
    clear { args = { '-u', 'NORC', '+set runtimepath+=test/functional/fixtures' } }
    command('set nofoldenable nowrap laststatus=0')
  end)

  it('opens directly if no buffer created', function()
    local screen = Screen.new(50, 12, { ext_multigrid = true })
    screen:set_default_attr_ids {
      h1 = { reverse = true },
      h2 = { foreground = tonumber('0x6a0dad') },
      [1] = { foreground = Screen.colors.Blue, bold = true },
      [14] = { foreground = Screen.colors.LightGrey, background = Screen.colors.DarkGray },
      [32] = { foreground = Screen.colors.PaleGreen2 },
    }
    command('checkhealth success1')
    screen:expect {
      grid = [[
    ## grid 1
      [2:--------------------------------------------------]|*11
      [3:--------------------------------------------------]|
    ## grid 2
      ^                                                  |
      {14:                                                  }|
      {14:                            }                      |
      {h1:test_plug.                                        }|
      {h1:success1:                                         }|
      {h1:                ✅}                                |
                                                        |
      {h2:report 1}                                          |
      - ✅ {32:OK} everything is fine                        |
                                                        |
      {h2:report 2}                                          |
    ## grid 3
                                                        |
    ]],
    }
  end)

  local function test_health_vsplit(left, emptybuf, mods)
    local screen = Screen.new(50, 20, { ext_multigrid = true })
    screen:set_default_attr_ids {
      h1 = { reverse = true },
      h2 = { foreground = tonumber('0x6a0dad') },
      [1] = { foreground = Screen.colors.Blue, bold = true },
      [14] = { foreground = Screen.colors.LightGrey, background = Screen.colors.DarkGray },
      [32] = { foreground = Screen.colors.PaleGreen2 },
    }
    if not emptybuf then
      insert('hello')
    end
    command(mods .. ' checkhealth success1')
    screen:expect(
      ([[
    ## grid 1
      %s
      [3:--------------------------------------------------]|
    ## grid 2
      %s                   |
      {1:~                       }|*18
    ## grid 3
                                                        |
    ## grid 4
      ^                         |
      {14:                         }|*3
      {14:   }                      |
      {h1:test_plug.               }|
      {h1:success1:                }|
      {h1:                         }|
      {h1:                ✅}       |
                               |
      {h2:report 1}                 |
      - ✅ {32:OK} everything is    |
      fine                     |
                               |
      {h2:report 2}                 |
      - ✅ {32:OK} nothing to see   |
      here                     |
                               |
      {1:~                        }|
    ]]):format(
        left and '[4:-------------------------]│[2:------------------------]|*19'
          or '[2:------------------------]│[4:-------------------------]|*19',
        emptybuf and '     ' or 'hello'
      )
    )
  end

  for _, mods in ipairs({ 'vertical', 'leftabove vertical', 'topleft vertical' }) do
    it(('opens in left vsplit window with :%s and no buffer created'):format(mods), function()
      test_health_vsplit(true, true, mods)
    end)
    it(('opens in left vsplit window with :%s and non-empty buffer'):format(mods), function()
      test_health_vsplit(true, false, mods)
    end)
  end

  for _, mods in ipairs({ 'rightbelow vertical', 'botright vertical' }) do
    it(('opens in right vsplit window with :%s and no buffer created'):format(mods), function()
      test_health_vsplit(false, true, mods)
    end)
    it(('opens in right vsplit window with :%s and non-empty buffer'):format(mods), function()
      test_health_vsplit(false, false, mods)
    end)
  end

  local function test_health_split(top, emptybuf, mods)
    local screen = Screen.new(50, 25, { ext_multigrid = true })
    screen._default_attr_ids = nil
    if not emptybuf then
      insert('hello')
    end
    command(mods .. ' checkhealth success1')
    screen:expect(
      ([[
    ## grid 1
%s
      [3:--------------------------------------------------]|
    ## grid 2
      %s                                             |
      ~                                                 |*10
    ## grid 3
                                                        |
    ## grid 4
      ^                                                  |
                                                        |
                                                        |
      test_plug.                                        |
      success1:                                         |
                      ✅                                |
                                                        |
      report 1                                          |
      - ✅ OK everything is fine                        |
                                                        |
      report 2                                          |
      - ✅ OK nothing to see here                       |
    ]]):format(
        top
            and [[
      [4:--------------------------------------------------]|*12
      health:// [-]                                     |
      [2:--------------------------------------------------]|*11]]
          or ([[
      [2:--------------------------------------------------]|*11
      [No Name] %s                                     |
      [4:--------------------------------------------------]|*12]]):format(
            emptybuf and '   ' or '[+]'
          ),
        emptybuf and '     ' or 'hello'
      )
    )
  end

  for _, mods in ipairs({ 'horizontal', 'leftabove', 'topleft' }) do
    it(('opens in top split window with :%s and no buffer created'):format(mods), function()
      test_health_split(true, true, mods)
    end)
    it(('opens in top split window with :%s and non-empty buffer'):format(mods), function()
      test_health_split(true, false, mods)
    end)
  end

  for _, mods in ipairs({ 'rightbelow', 'botright' }) do
    it(('opens in bottom split window with :%s and no buffer created'):format(mods), function()
      test_health_split(false, true, mods)
    end)
    it(('opens in bottom split window with :%s and non-empty buffer'):format(mods), function()
      test_health_split(false, false, mods)
    end)
  end

  it('opens in tab', function()
    -- create an empty buffer called "my_buff"
    api.nvim_create_buf(false, true)
    command('file my_buff')
    command('checkhealth success1')
    -- define a function that collects all buffers in each tab
    -- returns a dict like {tab1 = ["buf1", "buf2"], tab2 = ["buf3"]}
    source([[
        function CollectBuffersPerTab()
                let buffs = {}
                for i in range(tabpagenr('$'))
                  let key = 'tab' . (i + 1)
                  let value = []
                  for j in tabpagebuflist(i + 1)
                    call add(value, bufname(j))
                  endfor
                  let buffs[key] = value
                endfor
                return buffs
        endfunction
    ]])
    local buffers_per_tab = fn.CollectBuffersPerTab()
    eq(buffers_per_tab, { tab1 = { 'my_buff' }, tab2 = { 'health://' } })
  end)
end)
