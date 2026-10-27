defmodule Theine.Test.Trace do
  @moduledoc """
  Runs a function in a fresh, call-traced process and returns the multiset of
  external calls it made into the listed modules (specs/01 §Acceptance).

  Uses an OTP 27 trace session, so concurrent async tests tracing the same
  modules do not see each other's calls or clobber each other's patterns.

      assert Theine.Test.Trace.calls([:ets], fn -> :ets.lookup(t, k) end) ==
               %{{:ets, :lookup, 2} => 1}
  """

  @type mfa_count :: %{optional(mfa()) => pos_integer()}

  @doc """
  Calls `fun` in a new process traced for calls to `modules` and returns
  `%{{module, function, arity} => count}`. An exception, throw or exit in
  `fun` is re-raised in the caller.
  """
  @spec calls([module()], (-> term())) :: mfa_count()
  def calls(modules, fun) when is_list(modules) and is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        receive do
          ^ref -> :ok
        end

        result =
          try do
            fun.()
            :ok
          catch
            kind, reason -> {kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, result})
      end)

    session = :trace.session_create(__MODULE__, self(), [])

    try do
      for module <- modules do
        Code.ensure_loaded!(module)
        :trace.function(session, {module, :_, :_}, true, [])
      end

      1 = :trace.process(session, pid, true, [:call])
      send(pid, ref)

      result =
        receive do
          {^ref, result} -> result
          {:DOWN, ^monitor, :process, ^pid, reason} -> {:exit, reason, []}
        end

      delivered = :erlang.trace_delivered(pid)

      receive do
        {:trace_delivered, ^pid, ^delivered} -> :ok
      end

      calls = collect(pid, %{})

      case result do
        :ok -> calls
        {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
      end
    after
      :trace.session_destroy(session)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect(pid, acc) do
    receive do
      {:trace, ^pid, :call, {m, f, args}} ->
        collect(pid, Map.update(acc, {m, f, length(args)}, 1, &(&1 + 1)))
    after
      0 -> acc
    end
  end
end
