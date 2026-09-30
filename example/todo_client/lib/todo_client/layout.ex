defmodule TodoClient.Layout do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>Todos · ash_remote</title>
        <style>
          :root { font-family: system-ui, sans-serif; color: #223047; background: #f5f7fb; }
          body { margin: 0; }
          button, input, select { font: inherit; }
          button { cursor: pointer; }
          .demo-page { max-width: 54rem; margin: 0 auto 4rem; padding: 1.5rem 1rem; }
          .demo-header { display: flex; align-items: baseline; gap: .8rem; flex-wrap: wrap; margin-bottom: 1.4rem; }
          .demo-header h1 { margin: 0; font-size: 1.8rem; }
          .demo-header small { color: #64748b; }
          .demo-header a { margin-left: auto; }
          .panel, .list-card { background: white; border: 1px solid #dfe5ed; border-radius: .85rem; box-shadow: 0 3px 14px #172b4d0b; padding: 1rem 1.2rem; margin-bottom: 1rem; }
          .panel h2 { margin: 0 0 .8rem; font-size: 1.1rem; }
          .entry-form { display: flex; align-items: center; flex-wrap: wrap; gap: .6rem; }
          .entry-form > input:not([type=hidden]), .entry-form select { min-width: 10rem; padding: .6rem .7rem; border: 1px solid #cbd5e1; border-radius: .5rem; background: white; }
          .entry-form > input:not([type=hidden]) { flex: 1; }
          .check-label { display: inline-flex; align-items: center; gap: .35rem; font-size: .86rem; white-space: nowrap; }
          .primary-button { border: 0; border-radius: .5rem; padding: .65rem .9rem; background: #2659d9; color: white; font-weight: 650; }
          .list-heading { display: flex; align-items: center; gap: .55rem; margin-bottom: .5rem; }
          .list-heading h2 { margin: 0; font-size: 1.15rem; }
          .list-heading small { margin-left: auto; color: #64748b; }
          .todo-row { display: flex; align-items: center; gap: .5rem; border-top: 1px solid #edf1f5; padding: .55rem 0; min-width: 0; }
          .toggle-button, .delete-button, .text-button { background: none; border: 0; padding: .2rem; }
          .toggle-button { font-size: 1.2rem; color: #2659d9; }
          .delete-button { color: #b42318; font-size: 1.3rem; }
          .text-button { color: #2659d9; font-size: .76rem; white-space: nowrap; }
          .todo-title, .todo-title-form { flex: 1; min-width: 6rem; }
          .todo-title-form input { width: 100%; box-sizing: border-box; border: 1px solid transparent; border-radius: .3rem; padding: .25rem; }
          .todo-title-form input:focus { border-color: #2659d9; }
          .done { color: #94a3b8; text-decoration: line-through; }
          .pill, .visibility { font-size: .7rem; border-radius: 99px; padding: .2rem .45rem; white-space: nowrap; }
          .public { color: #174db5; background: #e9f1ff; }
          .private, .muted, .source { color: #64748b; background: #f1f5f9; }
          .overdue, .parked { color: #a32020; background: #fff0ef; }
          .pending { color: #8a6500; background: #fff7d9; }
          .synced { color: #196b40; background: #e7f7ec; }
          .notice { display: flex; gap: 1rem; align-items: center; justify-content: space-between; padding: .65rem .8rem; margin-bottom: 1rem; border-radius: .55rem; font-size: .87rem; }
          .notice-info { color: #15528a; background: #eaf5ff; }
          .notice-error { color: #a32020; background: #fff0ef; }
          .notice button { border: 0; background: transparent; color: inherit; font-size: 1.3rem; line-height: 1; }
          .form-error { color: #a32020; font-size: .82rem; margin: .4rem 0 0; }
          .empty-state { color: #64748b; font-size: .87rem; }
          @media (max-width: 620px) { .todo-row { flex-wrap: wrap; } .entry-form select { flex: 1; } }
        </style>
        <script src="/js/phoenix/phoenix.js">
        </script>
        <script src="/js/live_view/phoenix_live_view.js">
        </script>
        <script>
          const csrf = document.querySelector("meta[name=csrf-token]").content
          const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrf}
          })
          liveSocket.connect()
        </script>
      </head>
      <body>
        <nav style="display:flex; gap:.25rem; padding:.5rem .75rem; border-bottom:1px solid #eee; font-family:system-ui, sans-serif; font-size:.85rem; align-items:center;">
          <strong style="margin-right:.75rem; color:#333;">ash_remote demo</strong>
          <a href="/" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#1a56c4; background:#eef3ff;">Online (cache)</a>
          <a href="/ledger" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#1a56c4; background:#eef3ff;">Coverage ledger</a>
          <a href="/offline" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#1a56c4; background:#eef3ff;">Offline (local-first)</a>
          <a href="/oban" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#7a3ba8; background:#f4ecfb;">Oban Web</a>
        </nav>
        {@inner_content}
      </body>
    </html>
    """
  end
end
