Logger.configure(level: :error)

alias FunWithFlags.{Flag, Gate}
alias FunWithFlags.Store.Cache

sizes =
  case System.get_env("ACTOR_GATES") do
    nil -> [1_000, 10_000, 100_000, 500_000]
    list -> list |> String.split(",") |> Enum.map(&String.to_integer/1)
  end

flag_name = fn n -> :"bench_actor_gates_#{n}" end

build_flag = fn n ->
  actor_gates = for i <- 1..n, do: %Gate{type: :actor, for: "user:#{i}", enabled: true}
  group_gates = [Gate.new(:group, "nope", false), Gate.new(:group, "nope2", true)]
  %Flag{name: flag_name.(n), gates: [Gate.new(:boolean, false) | group_gates ++ actor_gates]}
end

Cache.put(%Flag{name: :bench_boolean_only, gates: [Gate.new(:boolean, true)]})

inputs = for n <- sizes, do: {"#{n} actor gates", n}

Benchee.run(
  %{
    "actor check (gate present)" => fn {name, n} ->
      FunWithFlags.enabled?(name, for: %PlainUser{id: div(n, 2), group: "foo"})
    end,
    "actor check (no gate for actor)" => fn {name, _n} ->
      FunWithFlags.enabled?(name, for: %PlainUser{id: 0, group: "foo"})
    end,
    "boolean check (same flag)" => fn {name, _n} ->
      FunWithFlags.enabled?(name)
    end,
    "boolean check (boolean-only flag)" => fn _ ->
      FunWithFlags.enabled?(:bench_boolean_only)
    end,
  },
  inputs: inputs,
  before_scenario: fn n ->
    {:ok, _} = Cache.put(build_flag.(n))
    Cache.put(%Flag{name: :bench_boolean_only, gates: [Gate.new(:boolean, true)]})
    {flag_name.(n), n}
  end,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "1")),
  time: String.to_integer(System.get_env("BENCH_TIME", "3")),
  memory_time: String.to_integer(System.get_env("BENCH_MEMORY_TIME", "1"))
)
