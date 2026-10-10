defmodule FunWithFlags.Store.CacheTest do
  use FunWithFlags.TestCase, async: false # mocks!
  import FunWithFlags.TestUtils
  import Mock

  alias FunWithFlags.Store.Cache
  alias FunWithFlags.{Timestamps, Config, Flag, Gate}

  setup do
    Cache.flush()
    name = unique_atom()
    gate = %Gate{type: :boolean, enabled: true}
    flag = %Flag{name: name, gates: [gate]}
    {:ok, name: name, flag: flag }
  end


  describe "put(%Flag{})" do
    test "put(%Flag{}) changes the cached flag", %{name: name, flag: flag} do
      assert {:miss, :not_found, nil} = Cache.get(name)
      Cache.put(flag)
      assert {:ok, ^flag} = Cache.get(name)

      flag2 = %Flag{ flag | gates: [Gate.new(:boolean, false)]}

      Cache.put(flag2)
      assert {:ok, ^flag2} = Cache.get(name)
      refute match? {:ok, ^flag}, Cache.get(name)
    end

    test "put(%Flag{}) returns the tuple {:ok, %Flag{}}", %{flag: flag} do
      assert {:ok, ^flag} = Cache.put(flag)
    end
  end


  describe "get(:flag_name)" do
    test "looking up an undefined flag returns {:miss, :not_found, nil}" do
      flag_name = unique_atom()
      assert {:miss, :not_found, nil} = Cache.get(flag_name)
    end

    test "looking up an already stored flag returns {:ok, %Flag{}}", %{name: name, flag: flag} do
      assert {:miss, :not_found, nil} = Cache.get(name)
      Cache.put(flag)
      assert {:ok, ^flag} = Cache.get(name)
    end


    test "looking up an expired flag returns {:miss, :expired, stale_value}", %{name: name, flag: flag}  do
      assert {:miss, :not_found, nil} = Cache.get(name)

      {:ok, ^flag} = Cache.put(flag)
      assert {:ok, ^flag} = Cache.get(name)

      # 1 second before expiring
      timetravel by: (Config.cache_ttl - 1) do
        assert {:ok, ^flag} = Cache.get(name)
      end

      # 1 second after expiring
      timetravel by: (Config.cache_ttl + 1) do
        assert {:miss, :expired, ^flag} = Cache.get(name)

        Cache.flush
        assert {:miss, :not_found, nil} = Cache.get(name)
      end
    end
  end


  describe "enabled?(flag_name, options)" do
    setup %{name: name} do
      actor_gates =
        for i <- 1..5_000 do
          Gate.new(:actor, %FunWithFlags.TestUser{id: i}, rem(i, 3) != 0)
        end

      group_gates = [
        Gate.new(:group, "muggles", false),
        Gate.new(:group, "wizards", true),
        Gate.new(:group, "dragons", true),
      ]

      flag = %Flag{name: name, gates: [Gate.new(:boolean, false)] ++ group_gates ++ actor_gates}
      Cache.put(flag)
      {:ok, flag: flag}
    end

    test "it returns :miss for a flag that is not cached" do
      assert :miss = Cache.enabled?(unique_atom(), [])
      assert :miss = Cache.enabled?(unique_atom(), for: %FunWithFlags.TestUser{id: 1})
    end

    test "with many actor gates, it finds the gate of the checked actor", %{name: name, flag: flag} do
      for i <- [1, 2, 3, 2_500, 4_998, 4_999, 5_000] do
        user = %FunWithFlags.TestUser{id: i, groups: ["muggles"]}
        assert {:ok, rem(i, 3) != 0} == Cache.enabled?(name, for: user)
        assert {:ok, Flag.enabled?(flag, for: user)} == Cache.enabled?(name, for: user)
      end
    end

    test "with many actor gates, an actor without a gate falls back to the other gates", %{name: name} do
      assert {:ok, false} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 10_001})
      assert {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 10_001, groups: ["wizards"]})
    end

    test "when an item belongs to an enabled and a disabled group, the disabled group wins", %{name: name} do
      user = %FunWithFlags.TestUser{id: 10_001, groups: ["dragons", "muggles", "wizards"]}
      assert {:ok, false} = Cache.enabled?(name, for: user)

      user = %FunWithFlags.TestUser{id: 10_001, groups: ["dragons", "wizards"]}
      assert {:ok, true} = Cache.enabled?(name, for: user)
    end

    test "an actor gate takes precedence over the group gates", %{name: name} do
      assert {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1, groups: ["muggles"]})
      assert {:ok, false} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 3, groups: ["wizards"]})
    end

    test "duplicate actor gates resolve to the first one, as with the full flag" do
      name = unique_atom()
      user = %FunWithFlags.TestUser{id: 1}
      flag = %Flag{name: name, gates: [Gate.new(:actor, user, false), Gate.new(:actor, user, true)]}
      Cache.put(flag)

      assert {:ok, false} = Cache.enabled?(name, for: user)
      assert {:ok, Flag.enabled?(flag, for: user)} == Cache.enabled?(name, for: user)
    end

    test "without the :for option, it checks the boolean gate" do
      name = unique_atom()
      Cache.put(%Flag{name: name, gates: [Gate.new(:actor, %FunWithFlags.TestUser{id: 1}, true), Gate.new(:boolean, true)]})
      assert {:ok, true} = Cache.enabled?(name, [])

      Cache.put(%Flag{name: name, gates: [Gate.new(:actor, %FunWithFlags.TestUser{id: 1}, true), Gate.new(:boolean, false)]})
      assert {:ok, false} = Cache.enabled?(name, [])
    end

    test "a flag with no gates is disabled" do
      name = unique_atom()
      Cache.put(%Flag{name: name, gates: []})
      assert {:ok, false} = Cache.enabled?(name, [])
      assert {:ok, false} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1})
    end

    test "items that only implement the Group protocol work when the flag has no actor gates" do
      name = unique_atom()
      Cache.put(%Flag{name: name, gates: [Gate.new(:boolean, true), Gate.new(:group, "muggles", false)]})
      assert {:ok, true} = Cache.enabled?(name, for: 42)
    end

    test "it falls back to the percentage_of_actors gate" do
      name = unique_atom()
      flag = %Flag{name: name, gates: [
        Gate.new(:boolean, false),
        Gate.new(:actor, %FunWithFlags.TestUser{id: 1}, false),
        Gate.new(:percentage_of_actors, 0.5),
      ]}
      Cache.put(flag)

      results =
        for i <- 1..200 do
          user = %FunWithFlags.TestUser{id: i}
          assert {:ok, enabled} = Cache.enabled?(name, for: user)
          assert Flag.enabled?(flag, for: user) == enabled
          enabled
        end

      assert {:ok, false} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1})
      assert Enum.any?(results)
      refute Enum.all?(results)
    end

    test "it falls back to the percentage_of_time gate, with and without the :for option" do
      name = unique_atom()
      flag = %Flag{name: name, gates: [
        Gate.new(:boolean, false),
        Gate.new(:actor, %FunWithFlags.TestUser{id: 1}, true),
        Gate.new(:percentage_of_time, 0.5),
      ]}
      Cache.put(flag)

      for i <- 1..100, options <- [[], [for: %FunWithFlags.TestUser{id: 2}]] do
        :rand.seed(:exsss, {i, i, i})
        expected = Flag.enabled?(flag, options)
        :rand.seed(:exsss, {i, i, i})
        assert {:ok, ^expected} = Cache.enabled?(name, options)
      end

      assert {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1})
    end

    test "a true boolean gate wins over the percentage gates" do
      name = unique_atom()
      Cache.put(%Flag{name: name, gates: [Gate.new(:percentage_of_time, 0.0001), Gate.new(:boolean, true)]})
      for _ <- 1..20 do
        assert {:ok, true} = Cache.enabled?(name, [])
        assert {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1})
      end
    end

    test "it returns :miss for an expired flag", %{name: name} do
      user = %FunWithFlags.TestUser{id: 1}
      assert {:ok, true} = Cache.enabled?(name, for: user)

      timetravel by: (Config.cache_ttl - 1) do
        assert {:ok, true} = Cache.enabled?(name, for: user)
      end

      timetravel by: (Config.cache_ttl + 1) do
        assert :miss = Cache.enabled?(name, for: user)
        assert :miss = Cache.enabled?(name, [])
      end
    end

    test "replacing a flag removes the rows of its previous gates", %{name: name} do
      user = %FunWithFlags.TestUser{id: 1}
      assert {:ok, true} = Cache.enabled?(name, for: user)

      new_flag = %Flag{name: name, gates: [Gate.new(:boolean, false), Gate.new(:actor, %FunWithFlags.TestUser{id: 2}, true)]}
      Cache.put(new_flag)

      assert {:ok, false} = Cache.enabled?(name, for: user)
      assert {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 2})
      assert {:ok, false} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 10_001, groups: ["wizards"]})
      assert {:ok, ^new_flag} = Cache.get(name)
      assert 4 = row_count(name)
      assert [{^name, {^new_flag, _, _}}] = Enum.filter(Cache.dump(), &(elem(&1, 0) == name))
    end

    test "flush() removes all the gate rows", %{name: name} do
      Cache.flush()
      assert :miss = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 1})
      assert 0 = row_count(name)
    end
  end


  describe "concurrent reads while a flag is replaced" do
    test "readers never observe a mix of the old and new gates, nor a missing flag" do
      name = unique_atom()
      user = %FunWithFlags.TestUser{id: 0}

      build = fn offset ->
        fillers = for i <- 1..2_000, do: Gate.new(:actor, %FunWithFlags.TestUser{id: offset + i}, false)
        %Flag{name: name, gates: [Gate.new(:actor, user, true), Gate.new(:boolean, true) | fillers]}
      end

      flags = [build.(0), build.(10_000)]
      Cache.put(hd(flags))

      writer = Task.async(fn ->
        for i <- 1..200, do: Cache.put(Enum.at(flags, rem(i, 2)))
        :done
      end)

      readers =
        for _ <- 1..4 do
          Task.async(fn -> read_until_done(writer.pid, name, user, flags, 0) end)
        end

      assert :done = Task.await(writer, 30_000)
      for reader <- readers do
        assert {:ok, reads} = Task.await(reader, 30_000)
        assert reads > 0
      end
    end
  end


  describe "a read interleaved with a replacement of the flag" do
    setup do
      name = unique_atom()
      user = %FunWithFlags.TestUser{id: 1}
      old_flag = %Flag{name: name, gates: [Gate.new(:boolean, false), Gate.new(:actor, user, true)]}
      new_flag = %Flag{name: name, gates: [Gate.new(:actor, user, true), Gate.new(:boolean, true), Gate.new(:group, "muggles", true)]}
      Cache.put(old_flag)
      {:ok, name: name, user: user, new_flag: new_flag}
    end

    test "an actor check started before the replacement reads the new gates", %{name: name, user: user, new_flag: new_flag} do
      assert {:ok, true} = read_paused_by_replacement(new_flag, fn -> Cache.enabled?(name, for: user) end)
    end

    test "a boolean check started before the replacement reads the new gates", %{name: name, new_flag: new_flag} do
      assert {:ok, true} = read_paused_by_replacement(new_flag, fn -> Cache.enabled?(name, []) end)
    end

    test "a group check started before the replacement reads the new gates", %{name: name, new_flag: new_flag} do
      user = %FunWithFlags.TestUser{id: 2, groups: ["muggles"]}
      assert {:ok, true} = read_paused_by_replacement(new_flag, fn -> Cache.enabled?(name, for: user) end)
    end
  end


  defp read_paused_by_replacement(new_flag, read) do
    test_pid = self()

    with_mock(Timestamps, [:passthrough], [
      expired?: fn(timestamp, ttl) ->
        if Process.delete(:pause_before_reading_gates) do
          send(test_pid, {:paused, self()})
          receive do
            :resume -> :ok
          end
        end
        :meck.passthrough([timestamp, ttl])
      end
    ]) do
      reader = Task.async(fn ->
        Process.put(:pause_before_reading_gates, true)
        read.()
      end)

      assert_receive {:paused, reader_pid}, 1_000
      assert {:ok, ^new_flag} = Cache.put(new_flag)
      send(reader_pid, :resume)
      Task.await(reader)
    end
  end


  defp row_count(name) do
    :ets.select_count(:fun_with_flags_cache, [
      {{name, :_, :_, :_, :_}, [], [true]},
      {{{name, :_, :_}, :_}, [], [true]},
    ])
  end


  defp read_until_done(writer_pid, name, user, flags, reads) do
    if Process.alive?(writer_pid) do
      {:ok, true} = Cache.enabled?(name, for: user)
      {:ok, true} = Cache.enabled?(name, [])
      {:ok, true} = Cache.enabled?(name, for: %FunWithFlags.TestUser{id: 5_000})
      {:ok, flag} = Cache.get(name)
      true = flag in flags
      read_until_done(writer_pid, name, user, flags, reads + 1)
    else
      {:ok, reads}
    end
  end


  describe "integration: enable and disable with the top-level API" do
    setup do
      # can't use setup_all in here, but the on_exit should
      # be run only once because it's identifed by a common ref
      on_exit(:cache_integration_group, fn() -> clear_test_db() end)
      :ok
    end

    test "looking up a disabled flag" do
      name = unique_atom()
      FunWithFlags.disable(name)
      assert {:ok, %Flag{name: ^name, gates: [%Gate{type: :boolean, enabled: false}]}} = Cache.get(name)
    end

    test "looking up an enabled flag" do
      name = unique_atom()
      FunWithFlags.enable(name)
      assert {:ok, %Flag{name: ^name, gates: [%Gate{type: :boolean, enabled: true}]}} = Cache.get(name)
    end
  end


  test "flush() empties the cache", %{flag: flag}  do
    Cache.put(flag)

    assert [{n, {f, t, x}}|_] = Cache.dump()
    assert is_atom(n)    # name
    assert %Flag{} = f   # value
    assert is_integer(t) # timestamp
    assert is_integer(x) # ttl

    Cache.flush()
    assert [] = Cache.dump()
  end


  test "dump() returns a List with the cached keys", %{name: name1, flag: flag1} do
    # because the test is faster than one second
    now = Timestamps.now
    ttl = Config.cache_ttl

    Cache.put(flag1)

    assert [{^name1, {^flag1, ^now, ^ttl}}|_] = Cache.dump()

    name2 = unique_atom()
    gate2 = %Gate{type: :boolean, enabled: true}
    flag2 = %Flag{name: name2, gates: [gate2]}
    Cache.put(flag2)

    name3 = unique_atom()
    gate3 = %Gate{type: :boolean, enabled: true}
    flag3 = %Flag{name: name3, gates: [gate3]}
    Cache.put(flag3)

    assert [{n, {f, t, x}}|_] = Cache.dump()
    assert is_atom(n)    # name
    assert %Flag{} = f   # value
    assert is_integer(t) # timestamp
    assert is_integer(x) # ttl

    kw = Cache.dump()
    assert is_list(kw)
    assert {^flag1, ^now, ^ttl} = Keyword.get(kw, name1)
    assert {^flag2, ^now, ^ttl} = Keyword.get(kw, name2)
    assert {^flag3, ^now, ^ttl} = Keyword.get(kw, name3)
  end
end
