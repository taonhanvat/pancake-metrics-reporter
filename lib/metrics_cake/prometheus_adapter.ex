defmodule MetricsCake.PrometheusAdapter do
  use Plug.Router

  plug Plug.Parsers, parsers: [:urlencoded, :multipart]
  plug :match
  plug :dispatch

  get "/" do
    callback = :persistent_term.get(:report_callback)
    callback_metrics = callback.()
    response = Jason.encode!(%{
      name: :os.cmd('hostname') |> List.to_string() |> String.trim(),
      payload: callback_metrics ++ reporter_metrics() ++ vm_metrics()
    })
    send_resp(conn, 200, response)
  end

  def start(opts) do
    report_callback = Keyword.get(opts, :report_callback, fn -> [] end)
    built_in_metrics = Keyword.get(opts, :built_in_metrics, [:cpu, :memory, :network])
    adapter_port = Keyword.get(opts, :adapter_port, 4001)
    :persistent_term.put(:report_callback, report_callback)
    :persistent_term.put(:built_in_metrics, built_in_metrics)
    Plug.Cowboy.http(__MODULE__, [], port: adapter_port)
  end

  defp reporter_metrics do
    pid = GenServer.whereis(MetricsCake)
    result = Process.info(pid, [:message_queue_len, :memory])
    memory_in_mb = Float.round(result[:memory] / 1024 / 1024, 2)
    [
      %{name: "pancake_metrics_reporter_msg_queue_len", value: result[:message_queue_len]},
      %{name: "pancake_metrics_reporter_memory", value: memory_in_mb}
    ]
  end

  defp vm_metrics do
    :persistent_term.get(:built_in_metrics)
    |> Task.async_stream(&collect/1)
    |> Enum.flat_map(fn {:ok, value} -> value end)
  end

  defp collect(:cpu = _metric) do
    shell_command = 'top -b -n 5 -d 0.2 | awk /Cpu/'
    line =
      :os.cmd(shell_command)
      |> List.to_string()
      |> String.trim()
      |> String.split("\n")
      |> List.last()

    [idle_perent] = Regex.run(~r/[\d\.]+(?= id)/, line)
    [
      %{
        name: "cpu_used",
        value: 100 - String.to_float(idle_perent) |> Float.round(2)
      }
    ]
  end

  defp collect(:memory = _metric) do
    shell_command = ~c(free -b | sed -n '2 p' | awk '{print $2,$4}')
    line =
      :os.cmd(shell_command)
      |> List.to_string()
      |> String.trim()
      |> String.split("\n")
      |> List.last()

    Regex.named_captures(~r/(?<total>\d+) (?<free>\d+)/, line)
    |> Enum.map(fn {key, value} ->
      name =
        case key do
          "total" -> "mem_total"
          "free" -> "mem_unused"
        end

      %{
        name: name,
        value: String.to_integer(value)
      }
    end)
  end

  defp collect(:network = _metric) do
    shell_command = ~c(sudo iftop -tB -s 2 -i eth0 | grep 'Total')
    lines =
      :os.cmd(shell_command)
      |> List.to_string()
      |> String.trim()
      |> String.split("\n")

    send_rate = Enum.find(lines, & String.contains?(&1, "Total send rate"))
    receive_rate = Enum.find(lines, & String.contains?(&1, "Total receive rate"))

    to_number = fn string ->
      if String.contains?(string, "."),
        do: String.to_float(string),
        else: String.to_integer(string)
    end

    convert_to_byte = fn
      value, "B" -> value
      value, "KB" -> value * 1024
      value, "MB" -> value * 1024 * 1024
    end

    regex = ~r/([\d\.]+)(B|KB|MB)/
    metrics = []
    metrics =
      case Regex.run(regex, send_rate) do
        [_, value, unit] ->
          metrics ++ [%{
            name: "pancake_network_bandwidth",
            value: to_number.(value) |> convert_to_byte.(unit),
            labels: %{direction: "egress", interface: "eth0"}
          }]

        nil -> metrics
      end

    metrics =
      case Regex.run(regex, receive_rate) do
        [_, value, unit] ->
          metrics ++ [%{
            name: "pancake_network_bandwidth",
            value: to_number.(value) |> convert_to_byte.(unit),
            labels: %{direction: "ingress", interface: "eth0"}
          }]

        nil -> metrics
      end

    metrics
  end
end
