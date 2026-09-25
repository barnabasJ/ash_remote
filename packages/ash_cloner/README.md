# AshCloner

Clone Ash resources into a user's application with
[Igniter](https://hexdocs.pm/igniter), and keep them up to date without
clobbering user edits.

## Why

Sharing Ash resources through packages is hard: a library can't just ship
resource modules, because users need to own, rename, and extend them — which
is why core packages ship hand-written Igniter installers. AshCloner flips
the authoring model: **write real, compilable, testable resources** (in your
library, or its example app), and ship a one-line installer that copies them
into the user's codebase. Your example app doubles as the template, and it's
tested like any other code.

## The pieces

- **`AshCloner.SourceCloner`** — turns resource source files from a
  dependency into `AshCloner.Definition`s: the actual source, re-namespaced
  by prefix swap (`MyLib.Blog.Post` → `MyApp.Content.Post`, including every
  qualified reference in the body), split into per-section entities.
  Everything you wrote survives — changes, preparations, helper functions,
  comments.
- **`AshCloner.apply_definitions/3`** — applies definitions to an
  `Igniter.t()`. Modules that don't exist are created whole. Existing
  modules are *never rewritten*: they only gain entities they're missing,
  by name. Disagreements (a changed entity, an entity the definitions no
  longer carry) are surfaced as warnings, or resolved per entity with
  `interactive: true` — keeping the user's version is always the default.
- **`mix ash_cloner.clone`** — a generic task over both:

  ```sh
  mix ash_cloner.clone \
    --modules MyLib.Blog.Post,MyLib.Blog.Comment,MyLib.Blog.Domain \
    --namespace MyApp.Content
  ```

## The wrap pattern (for library authors)

Ship your own installer so users don't spell out module lists:

```elixir
defmodule Mix.Tasks.MyLib.Install do
  @shortdoc "Install MyLib's resources into your app"
  @moduledoc "mix my_lib.install --namespace MyApp.Content"
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _parent) do
    %Igniter.Mix.Task.Info{
      schema: [namespace: :string, output: :string, interactive: :boolean],
      aliases: [n: :namespace, o: :output]
    }
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = igniter.args.options

    definitions =
      AshCloner.SourceCloner.from_modules(
        [MyLib.Blog.Post, MyLib.Blog.Comment, MyLib.Blog.Domain],
        namespace: options[:namespace] || Mix.raise("--namespace is required"),
        otp_app: Igniter.Project.Application.app_name(igniter)
      )

    AshCloner.apply_definitions(igniter, definitions,
      output: options[:output] || "lib",
      interactive: options[:interactive] || false,
      labels: [definitions: "my_lib's resources", upstream: "my_lib"]
    )
  end
end
```

Users install with `mix my_lib.install --namespace MyApp.Content`, and
update after a `mix deps.update my_lib` by running the same command again:
new entities arrive, their edits stay, drift is reported (or walked through
with `--interactive`).

## Update semantics (the ownership model)

No markers, no manifests, no bookkeeping: ownership is definition-set
membership, recomputed on every run.

- Module missing → created whole from `source`.
- Module exists → each definition entity is ensured **by name**; everything
  else in the file belongs to the user.
- Entity exists in both but differs → `:changed` drift. In the file but not
  the definitions → `:extra` drift (a user addition — or something the
  library removed). Either way nothing happens automatically: a warning by
  default, a per-entity prompt with `interactive: true`.
- Re-applying unchanged definitions is a no-op.

Comparisons are AST-level (formatting never counts as drift), and
validations — which have no name — compare by meaning:
`string_length(:title, min: 3)` equals
`{Ash.Resource.Validation.StringLength, [min: 3, attribute: :title]}` in
any option order.

## Dry runs

`apply_definitions/3` never touches the filesystem — every change is staged
on the `Igniter.t()`. Any `Igniter.Mix.Task` built on it (including
`mix ash_cloner.clone` and your wrapper) supports Igniter's standard
`--dry-run` and `--check` flags for free.

## Known limitations

Re-namespacing rewrites `__aliases__` nodes only. Module names built at
runtime (`Module.concat/1`, string interpolation) or written as raw atoms
(`:"Elixir.MyLib.Post"`) are not rewritten, and a bare re-`alias`ed prefix
(`alias MyLib.Blog` + `Blog.Post` in the body) is not followed — alias the
full module instead.

## Status

Developed inside the [ash_remote](../..) repo, which uses the same apply
engine for its manifest-generated remote resources. Not yet published to
hex (the `mix.exs` shares the parent repo's deps and lockfile for offline
development; that must be unwound before publishing).
