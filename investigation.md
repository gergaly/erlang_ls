### info
#### original
https://erlang-ls.github.io/
https://github.com/erlang-ls/erlang_ls
#### my fork
https://github.com/gergaly/erlang_ls
see branches
### org
#### build
erlang_ls for neovim is built by `nvim-lspconfig` and `mason`. Build instructions from `package.yaml`:
```yaml
source:
  # renovate:datasource=github-tags
  id: pkg:github/gergaly/erlang_ls@dev
  build:
    - target: win
      run: |
        rebar3 escriptize
      erlang_ls: _build/default/bin/erlang_ls.cmd
    - target: unix
      run: |
        </dev/null rebar3 escriptize
      erlang_ls: _build/default/bin/erlang_ls

bin:
  erlang_ls: "{{source.build.erlang_ls}}"
```
So, for neovim an escript is built and it is named `erlang_ls`. rebar3 looks for a `rebar.config` file for build information:
```erlang
{escript_emu_args, "%%! -connect_all false -hidden\n"}.
{escript_incl_extra, [{"els_lsp/priv/snippets/*", "_build/default/lib/"}]}.
{escript_main_app, els_lsp}.
{escript_name, erlang_ls}.
```
Details:
 * `{escript_name, erlang_ls}.`:  Name of the generated escript, and default module name to boot (`erlang_ls:main(_)`).
 * `{escript_main_app, els_lsp}.`: Name of the application to turn to an escript. So the top level app in our case is `els_lsp`
 And because `els_core` is listed as an included application by `els_lsp` it will be packaged in the escript as well.
### startup
#### original
the build process produces the `erlang_ls` escript.
```bash
rebar3 escriptize
```
* nvim starts the escript, from `{escript_name, erlang_ls}` -> `erlang_ls:main(Args)` will be called
* `erlang_ls:main` starts the `els_lsp` application
* the `els_lsp` application is started by the erlang application controller. From `els_lsp.app.src` the `{mod, {els_app, []}}` tells how to start it: `els_app:start([])`
* then the `els_sup` is started and the supervisor will start all of his children from `ChildSpecs` in `els_sup.erl`
* We care about `els_server` here. It is started with `start_link([])` by the supervisor
* `els_server:start_link/0` starts the gen_server and then it spawns the `els_stdio` process to handle the I/O
#### split
##### shell half, first phase
We produce the `els_shell` application with
```bash
rebar3 as split compile
```
* the node is started manually by %TODO
* `els_shell` app is started by `els_shell_app:start([])` by the application controller `els_shell.app.src` `{mod, {els_shell_app, []}}`
* `els_shell_app:start` start the erlang distribution with `els_server@127.0.0.1` name
* connects to `fake_ls@127.0.0.1` node
* starts the `els_shell_sup` supervisor
* the supervisor starts the `els_shell` gen_server
* the `els_shell` gen_server waits for the `{start_server, ...}` message from the escript half
##### escript half
We produce the `fake_ls` escript with
```bash
rebar3 as split escriptize
```
* nvim starts the escript, from `{escript_name, fake_ls}` -> `fake_ls:main(Args)` will be called
* `fake_ls:main` starts up the erlang distribution with `fake_ls@127.0.0.1` name
* connects to `els_server@172.0.0.1` node
* starts the `els_fake` gen_server
* and calls `els_fake:start_server([Args])` to start the lsp on the other node, the shell half
* which is done by `gen_server:cast({global, els_shell}, {start_server, ...})`
* this request is handled by the `els_shell` gen_server

##### shell half, second phase
* after the `start_server` message the `els_shell` gen_server starts the `els_lsp` application
* from this point the way is the same as in the original version
#### common section
* the common section starts with `els_server:start_link()`, in this function we should check for original or split mode
* but the els_server
