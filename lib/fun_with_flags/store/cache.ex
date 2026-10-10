defmodule FunWithFlags.Store.Cache do
  @moduledoc """
  The in-memory cache for the feature flag, backed by an ETS table.

  This module is not meant to be used directly, but some of its functions can be
  useful to debug flag state.
  """

  @type ttl :: integer
  @type cached_at :: integer

  @doc false
  use GenServer

  alias FunWithFlags.Actor
  alias FunWithFlags.Config
  alias FunWithFlags.Flag
  alias FunWithFlags.Gate
  alias FunWithFlags.Timestamps

  @table_name :fun_with_flags_cache
  @table_options [
    :set, :protected, :named_table, {:read_concurrency, true}
  ]


  @doc false
  def worker_spec do
    if FunWithFlags.Config.cache? do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, []},
        restart: :permanent,
        type: :worker,
      }
    end
  end


  @doc false
  def start_link do
    GenServer.start_link(__MODULE__, :ok, [name: __MODULE__])
  end


  # We lookup without going through the GenServer
  # for concurrency and performance.
  #
  @doc false
  def get(flag_name) do
    case entry(flag_name) do
      {_version, flag, timestamp, ttl} ->
        validate(flag, timestamp, ttl)
      nil ->
        {:miss, :not_found, nil}
    end
  end


  defp validate(flag, timestamp, ttl) do
    if Timestamps.expired?(timestamp, ttl) do
      {:miss, :expired, flag}
    else
      {:ok, flag}
    end
  end


  @doc false
  @spec enabled?(atom, Keyword.t) :: {:ok, boolean} | :miss
  def enabled?(flag_name, options) do
    case :ets.lookup(@table_name, flag_name) do
      [{^flag_name, version, timestamp, ttl, with_actors}] ->
        if Timestamps.expired?(timestamp, ttl) do
          :miss
        else
          gates = relevant_gates(flag_name, version, with_actors, options)
          result = Flag.enabled?(%Flag{name: flag_name, gates: gates}, options)
          if current_version?(flag_name, version) do
            {:ok, result}
          else
            enabled?(flag_name, options)
          end
        end
      _ ->
        :miss
    end
  end


  defp relevant_gates(flag_name, version, _with_actors, []) do
    gates_at(flag_name, version, [:boolean, :percentage_of_time])
  end

  defp relevant_gates(flag_name, version, false, [for: _item]) do
    non_actor_gates(flag_name, version)
  end

  defp relevant_gates(flag_name, version, true, [for: item]) do
    case gates_at(flag_name, version, [{:actor, Actor.id(item)}]) do
      [] -> non_actor_gates(flag_name, version)
      actor_gates -> actor_gates
    end
  end


  defp non_actor_gates(flag_name, version) do
    gates_at(flag_name, version, [:group, :boolean, :percentage_of_actors, :percentage_of_time])
  end


  defp gates_at(flag_name, version, kinds) do
    Enum.flat_map(kinds, fn kind ->
      case :ets.lookup(@table_name, {flag_name, version, kind}) do
        [{_key, gates}] -> gates
        [] -> []
      end
    end)
  end


  defp current_version?(flag_name, version) do
    match?([{^flag_name, ^version, _, _, _}], :ets.lookup(@table_name, flag_name))
  end


  defp entry(flag_name) do
    case :ets.lookup(@table_name, flag_name) do
      [{^flag_name, version, timestamp, ttl, _with_actors}] ->
        case :ets.lookup(@table_name, {flag_name, version, :flag}) do
          [{_key, flag}] -> {version, flag, timestamp, ttl}
          [] -> entry(flag_name)
        end
      [] ->
        nil
    end
  end


  # We want to always write serially through the
  # GenServer to avoid race conditions.
  #
  @doc false
  def put(flag = %Flag{}) do
    GenServer.call(__MODULE__, {:put, flag})
  end


  @doc """
  Clears the cache. It will be rebuilt gradually as the public interface of the
  package is queried.
  """
  @spec flush() :: true
  def flush do
    GenServer.call(__MODULE__, :flush)
  end


  @doc """
  Returns the flags stored in the cache ETS table, for inspection.
  """
  @spec dump() :: [{atom, {FunWithFlags.Flag.t, cached_at, ttl}}]
  def dump do
    @table_name
    |> :ets.select([{{:"$1", :_, :_, :_, :_}, [{:is_atom, :"$1"}], [:"$1"]}])
    |> Enum.flat_map(fn flag_name ->
      case entry(flag_name) do
        {_version, flag, timestamp, ttl} -> [{flag_name, {flag, timestamp, ttl}}]
        nil -> []
      end
    end)
  end


  # ------------------------------------------------------------
  # GenServer callbacks


  @doc false
  def init(:ok) do
    tab_name = @table_name
    ^tab_name = :ets.new(@table_name, @table_options)
    {:ok, %{tab_name: tab_name, ttl: Config.cache_ttl}}
  end


  @doc false
  def handle_call({:put, flag = %Flag{name: name}}, _from, state = %{ttl: ttl}) do
    previous = entry(name)
    version = :erlang.unique_integer([:positive, :monotonic])
    with_actors = Enum.any?(flag.gates, &Gate.actor?/1)
    # writing to an ETS table will either return true or raise
    :ets.insert(@table_name, [{name, version, Timestamps.now, ttl, with_actors} | rows(flag, version)])
    delete_rows(previous)
    {:reply, {:ok, flag}, state}
  end


  @doc false
  def handle_call(:flush, _from, state) do
    {:reply, :ets.delete_all_objects(@table_name), state}
  end


  defp rows(flag = %Flag{name: name, gates: gates}, version) do
    singles =
      for type <- [:boolean, :percentage_of_time, :percentage_of_actors],
          gate <- [Enum.find(gates, &(&1.type == type))],
          gate != nil,
          do: {{name, version, type}, [gate]}

    groups =
      case Enum.filter(gates, &Gate.group?/1) do
        [] -> []
        group_gates -> [{{name, version, :group}, group_gates}]
      end

    actors =
      gates
      |> Enum.filter(&Gate.actor?/1)
      |> Enum.uniq_by(&(&1.for))
      |> Enum.map(&{{name, version, {:actor, &1.for}}, [&1]})

    [{{name, version, :flag}, flag} | singles ++ groups ++ actors]
  end


  defp delete_rows(nil), do: :ok

  defp delete_rows({version, flag, _timestamp, _ttl}) do
    flag
    |> rows(version)
    |> Enum.each(fn {key, _value} -> :ets.delete(@table_name, key) end)
  end
end
