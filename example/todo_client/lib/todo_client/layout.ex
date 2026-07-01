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
        <script src="/js/phoenix/phoenix.js"></script>
        <script src="/js/live_view/phoenix_live_view.js"></script>
        <script>
          const csrf = document.querySelector("meta[name=csrf-token]").content
          const liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrf}
          })
          liveSocket.connect()
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
