# Benchmarks

Some simple benchmark scripts for the package. Use them as they are or modify them to test specific scenarios.

Example with Redis:

```
rm -r _build/dev/lib/fun_with_flags/ &&
PERSISTENCE=redis CACHE_ENABLED=true mix run benchmarks/flag.exs
```

Running the benchmarks with Ecto:

```
rm -r _build/dev/lib/fun_with_flags/ &&
PERSISTENCE=ecto RDBMS=postgres CACHE_ENABLED=false mix run benchmarks/persistence.exs
```

Checking a flag with a growing number of actor gates (1k, 10k, 100k and 500k by default, or a comma-separated list in `ACTOR_GATES`):

```
rm -r _build/dev/lib/fun_with_flags/ &&
PERSISTENCE=redis CACHE_ENABLED=true mix run benchmarks/actor_gates.exs
```
