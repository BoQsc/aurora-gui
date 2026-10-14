# Latency and correctness validation

These probes distinguish provider wait, generation, request count, and answer
correctness. They use the configured provider and exact selected model with
synthetic messages and isolated coding workspaces. They do not edit the user's
settings or real conversations. Credentials stay out of command arguments and
reports; temporary coding state is removed after each attempt and on exceptions.

From the repository root on Windows, with Python and DMD available:

```powershell
python aurora-opencode-pro/benchmarks/validate_latency.py --phase build --output aurora-opencode-pro/build/latency-validation/live.json
python aurora-opencode-pro/benchmarks/validate_batching.py --app aurora-opencode-pro/build/latency-validation/benchmark_app_path.exe --output aurora-opencode-pro/build/latency-validation/batching.json
python aurora-opencode-pro/benchmarks/validate_latency.py --phase direct --client aurora-opencode-pro/build/latency-validation/validation_client.exe --output aurora-opencode-pro/build/latency-validation/live.json --repeats 2
python aurora-opencode-pro/benchmarks/validate_latency.py --phase app --app aurora-opencode-pro/build/latency-validation/benchmark_app_path.exe --output aurora-opencode-pro/build/latency-validation/live.json
```

Run `compaction_validation.exe` in its output directory to inspect retention of
a middle-of-message reference fact under three deterministic compaction budgets.
This audits the fallback projection, not the quality of a generated model summary.
The test checks that saved conversation history remains unchanged.

The direct matrix uses high, low and off reasoning, two repetitions in reversed
profile order, exact answer checks, three context sizes, and observed cache token
counts. The coding matrix uses Aurora's actual conversation and tool loop on
three different tasks at high and low reasoning. Independent compilation,
execution and hidden behavior assertions determine correctness.

The local provider fixture controls server delays and verifies tool pairing,
independent batching, dependent reads, missing-file failure propagation, and
cancellation before response headers. Model request counts and timings are saved.

One or two repetitions are a screening test, not statistical proof. Cold and warm
cache states, service load, background activity and stochastic model behavior can
affect results. Faster incorrect answers are failures. A synthetic batching win
does not prove that a new prompt will cause the agent to batch in every task.
No finite matrix establishes a universal speedup or preserves every possible fact
after lossy compaction. Keep explicit user reasoning/context choices unless a
scoped change has adequate evidence, including the relevant correctness checks.
