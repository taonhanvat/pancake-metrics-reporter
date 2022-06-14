defmodule MetricsCake do
  use GenServer
  alias MetricsCake.TDigest

  @summary_metrics [:median, :p95, :p99]
  @summary_buffer_size 1_000
  @summary_retain_window 30 * 60 * 1_000 # 30 mins

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    metrics =
      Keyword.get(opts, :metrics, [])
      |> Enum.map(&expand_reporter_options/1)

    :ets.new(:metrics_reporter_utils, [:set, :named_table, :public])
    groups = Enum.group_by(metrics, & &1.event_name)

    for {event, metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.attach(id, event, &handle_event/4, metrics)
      Enum.each(metrics, &init_metric/1)
    end

    adapter = start_prometheus_adapter(opts)
    {:ok, %{metrics: metrics, adapter: adapter, opts: opts}}
  end

  def terminate(_, %{metrics: metrics}) do
    groups = Enum.group_by(metrics, & &1.event_name)
    for {event, _metrics} <- groups do
      id = {__MODULE__, event, self()}
      :telemetry.detach(id)
    end
  end

  def report(), do: GenServer.call(__MODULE__, :report)

  def handle_call(:report, _from, %{metrics: metrics} = state) do
    result = Enum.map(metrics, &report_metric/1)
    {:reply, result, state}
  end

  def handle_cast({:event, measurements, metadata, metrics}, state) do
    do_handle_event(measurements, metadata, metrics)
    {:noreply, state}
  end

  def handle_info({:reset_summary, metric}, state) do
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), [{2, TDigest.new()}, {4, NaiveDateTime.utc_now()}])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{adapter: pid} = state) do
    adapter = start_prometheus_adapter(state.opts)
    {:noreply, %{state | adapter: adapter}}
  end

  def handle_event(_event_name, measurements, metadata, metrics) do
    {can_update_concurrently_metrics, single_thread_update_metrics} =
      Enum.split_with(metrics, fn metric ->
        case metric do
          %Telemetry.Metrics.Counter{} -> true
          %Telemetry.Metrics.Summary{} -> false
          _ -> false
        end
      end)

    Enum.each(can_update_concurrently_metrics, fn metric ->
      if keep?(metric, metadata),
        do: do_handle_event(measurements, metadata, [metric])
    end)

    # Sử dụng GenServer để đảm bảo single-thread
    Enum.each(single_thread_update_metrics, fn metric ->
      if keep?(metric, metadata),
        do: GenServer.cast(__MODULE__, {:event, measurements, metadata, [metric]})
    end)
  end

  defp start_prometheus_adapter(opts) do
    adapter =
      case __MODULE__.PrometheusAdapter.start(opts) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.monitor(adapter)
    adapter
  end

  defp do_handle_event(measurements, metadata, metrics) do
    Enum.each(metrics, fn metric ->
      measurement = extract_measurement(metric, measurements, metadata)
      update_metric(metric, measurement, metadata)
    end)
  end

  defp init_metric(%Telemetry.Metrics.Counter{} = metric) do
    #{key, counter, since}
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), :counters.new(1, []), System.monotonic_time()})
  end

  defp init_metric(%Telemetry.Metrics.Summary{} = metric) do
    # {key, t_digest, buffer, last_reset}
    true = :ets.insert_new(:metrics_reporter_utils, {ets_key(metric), TDigest.new(), [], nil})
    :timer.send_interval(@summary_retain_window, self(), {:reset_summary, metric})
  end

  defp init_metric(_), do: :noop

  defp update_metric(%Telemetry.Metrics.Counter{} = metric, _measurement, _metadata) do
    [{_, counter, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    :counters.add(counter, 1, 1)
  end

  defp update_metric(%Telemetry.Metrics.Summary{} = metric, measurement, _metadata)
    when measurement != nil
  do
    [{_, t_digest, buffer, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    buffer = [measurement | buffer]
    if length(buffer) > @summary_buffer_size do
      updated = TDigest.update(t_digest, buffer)
      :ets.update_element(:metrics_reporter_utils, ets_key(metric), [{2, updated}, {3, []}])
    else
      :ets.update_element(:metrics_reporter_utils, ets_key(metric), {3, buffer})
    end
  end

  defp update_metric(_, _, _), do: :noop

  defp report_metric(%Telemetry.Metrics.Counter{} = metric) do
    [{_, counter, since}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))
    value = :counters.get(counter, 1)
    :counters.sub(counter, 1, value)
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), {3, System.monotonic_time()})
    duration = System.convert_time_unit(
      System.monotonic_time() - since,
      :native,
      :millisecond
    )

    sample_rate = metric.reporter_options[:sample_rate]
    value = if sample_rate, do: value / sample_rate, else: value

    %{
      metric: metric,
      report: %{total: value, duration: duration, per_sec: Float.round(value / (duration / 1000), 2)}
    }
  end

  defp report_metric(%Telemetry.Metrics.Summary{} = metric) do
    [{_, t_digest, buffer, _}] = :ets.lookup(:metrics_reporter_utils, ets_key(metric))

    # Flush everything in the buffer before report
    t_digest = TDigest.update(t_digest, buffer)
    :ets.update_element(:metrics_reporter_utils, ets_key(metric), [{2, t_digest}, {3, []}])

    interested_metrics = Keyword.get(metric.reporter_options, :metrics, [])
    report =
      for metric <- interested_metrics, metric in @summary_metrics, into: %{} do
        value =
          case metric do
            :median -> TDigest.percentile(t_digest, 0.5)
            :p95 -> TDigest.percentile(t_digest, 0.95)
            :p99 -> TDigest.percentile(t_digest, 0.99)
          end

        {metric, value}
      end

    %{
      metric: metric,
      report: report
    }
  end

  defp report_metric(metric), do: %{metric: metric, report: nil}

  defp ets_key(%Telemetry.Metrics.Counter{name: name}), do: {:counter, name}
  defp ets_key(%Telemetry.Metrics.Summary{name: name}), do: {:summary, name}

  defp extract_measurement(metric, measurements, metadata) do
    case metric.measurement do
      fun when is_function(fun, 2) -> fun.(measurements, metadata)
      fun when is_function(fun, 1) -> fun.(measurements)
      key -> measurements[key]
    end
  end

  defp keep?(%{keep: nil}, _metadata), do: true
  defp keep?(metric, metadata), do: metric.keep.(metadata)

  defp sample_rate(1), do: fn _ -> true end
  defp sample_rate(rate), do: fn _ -> :rand.uniform() < rate end

  defp expand_reporter_options(%{reporter_options: options} = metric) do
    if options[:sample_rate] do
      keep =
        case metric do
          %{keep: nil} -> sample_rate(options[:sample_rate])
          %{keep: func} -> fn metadata ->
            func.(metadata) && sample_rate(options[:sample_rate]).(metadata)
          end
        end

      %{metric | keep: keep}
    else
      metric
    end
  end
end
