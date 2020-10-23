defmodule Finch.HTTP1.Pool do
  @moduledoc false
  @behaviour NimblePool
  @behaviour Finch.Pool

  alias Finch.Conn
  alias Finch.Telemetry

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link({shp, registry_name, pool_size, conn_opts}) do
    NimblePool.start_link(
      worker: {__MODULE__, {registry_name, shp, conn_opts}},
      pool_size: pool_size,
      strategy: :lifo
    )
  end

  @impl Finch.Pool
  def request(pool, req, acc, fun, opts) do
    pool_timeout = Keyword.get(opts, :pool_timeout, 5_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 15_000)

    metadata = %{
      scheme: req.scheme,
      host: req.host,
      port: req.port,
      pool: pool
    }

    start_time = Telemetry.start(:queue, metadata)

    try do
      NimblePool.checkout!(
        pool,
        :checkout,
        fn from, {state, conn, idle_time} ->
          Telemetry.stop(:queue, start_time, metadata, %{idle_time: idle_time})

          with {:ok, conn} <- Conn.connect(conn),
               {:ok, conn, acc} <- Conn.request(conn, req, acc, fun, receive_timeout) do
            {{:ok, acc}, transfer_if_open(conn, state, from)}
          else
            {:error, conn, error} ->
              {{:error, error}, transfer_if_open(conn, state, from)}
          end
        end,
        pool_timeout
      )
    catch
      :exit, data ->
        Telemetry.exception(:queue, start_time, :exit, data, __STACKTRACE__, metadata)
        exit(data)
    end
  end

  @impl NimblePool
  def init_pool({registry, shp, opts}) do
    # Register our pool with our module name as the key. This allows the caller
    # to determine the correct pool module to use to make the request
    {:ok, _} = Registry.register(registry, shp, __MODULE__)
    {:ok, {shp, opts}}
  end

  @impl NimblePool
  def init_worker({{scheme, host, port}, opts} = pool_state) do
    {:ok, Conn.new(scheme, host, port, opts, self()), pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _, %{mint: nil} = conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin
    {:ok, {:fresh, conn, idle_time}, conn, pool_state}
  end

  def handle_checkout(:checkout, _from, conn, pool_state) do
    idle_time = System.monotonic_time() - conn.last_checkin

    case Conn.set_mode(conn, :passive) do
      {:ok, conn} -> {:ok, {:reuse, conn, idle_time}, conn, pool_state}
      _ -> {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_checkin(checkin, _from, _old_conn, pool_state) do
    with {:ok, conn} <- checkin,
         {:ok, conn} <- Conn.set_mode(conn, :active) do
      {:ok, %{conn | last_checkin: System.monotonic_time()}, pool_state}
    else
      _ ->
        {:remove, :closed, pool_state}
    end
  end

  @impl NimblePool
  def handle_update(new_conn, _old_conn, pool_state) do
    {:ok, new_conn, pool_state}
  end

  @impl NimblePool
  def handle_info(message, conn) do
    case Conn.discard(conn, message) do
      {:ok, conn} -> {:ok, conn}
      :unknown -> {:ok, conn}
      {:error, _error} -> {:remove, :closed}
    end
  end

  @impl NimblePool
  # On terminate, effectively close it.
  # This will succeed even if it was already closed or if we don't own it.
  def terminate_worker(_reason, conn, pool_state) do
    Conn.close(conn)
    {:ok, pool_state}
  end

  defp transfer_if_open(conn, state, {pid, _} = from) do
    if Conn.open?(conn) do
      if state == :fresh do
        NimblePool.update(from, conn)

        case Conn.transfer(conn, pid) do
          {:ok, conn} -> {:ok, conn}
          {:error, _, _} -> :closed
        end
      else
        {:ok, conn}
      end
    else
      :closed
    end
  end
end
