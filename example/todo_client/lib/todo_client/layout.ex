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
          <a href="/offline" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#1a56c4; background:#eef3ff;">Offline (local-first)</a>
          <a href="/oban" style="padding:.3rem .7rem; border-radius:.4rem; text-decoration:none; color:#7a3ba8; background:#f4ecfb;">Oban Web</a>
        </nav>
        {@inner_content}
      </body>
    </html>
    """
  end
end
