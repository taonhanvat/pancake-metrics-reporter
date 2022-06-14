defmodule MetricsCake.TDigest do
  alias MetricsCake.TDigest

  @moduledoc """
  All credit goes to https://github.com/meyercm/elixir-t_digest
  """

  @default_delta 0.1
  @default_autocompress_threshold 250
  defstruct [
    clusters: [],
    count: 0,
    delta: nil,
    autocompress_threshold: nil
  ]

  def new(opts \\ []) do
    delta = Keyword.get(opts, :delta, @default_delta)
    autocompress_threshold = Keyword.get(opts, :autocompress_threshold, @default_autocompress_threshold)
    %__MODULE__{delta: delta, autocompress_threshold: autocompress_threshold}
  end

  def update(digest, data)
  def update(digest, %__MODULE__{clusters: c}), do: update(digest, c)
  def update(digest, _first.._last = range), do: update(digest, Enum.to_list(range))
  def update(digest, list) when is_list(list) do
    Enum.reduce(list, digest, fn
      {v, w}, d -> do_update(d, v, w)
      v, d -> do_update(d, v, 1)
    end)
    |> maybe_compress()
  end

  def update(digest, value, weight \\ 1) do
    do_update(digest, value, weight)
    |> maybe_compress()
  end

  def percentile(%{clusters: clusters, count: count}, p) do
    do_percentile(clusters, p, count, 0)
  end

  def quantile(%{clusters: clusters, count: count}, value) do
    do_quantile(clusters, value, count, 0)
  end

  def compress(%{clusters: clusters, delta: delta, autocompress_threshold: autocompress_threshold}) do
    new_t_digest = TDigest.new(delta: delta, autocompress_threshold: nil)
    new_t_digest =
      clusters
      |> Enum.shuffle()
      |> Enum.reduce(new_t_digest, fn {v, w}, d -> do_update(d, v, w) end)
      |> round_count()
    %{new_t_digest | autocompress_threshold: autocompress_threshold}
  end

  defp do_update(%__MODULE__{clusters: []} = digest, value, weight) do
    %__MODULE__{digest|clusters: [{value, weight}], count: weight}
  end
  defp do_update(%{clusters: clusters, delta: delta, count: count} = digest, value, weight) do
    new_clusters = update_clusters(clusters, count, value, weight, delta)
    %__MODULE__{digest | clusters: new_clusters, count: count + weight}
  end

  defp update_clusters(clusters, count, value, weight, delta, cluster_acc \\ [], q_acc \\ 0)
  defp update_clusters(clusters, _count, _value, 0, _delta, _c_acc, _q_acc), do: clusters
  defp update_clusters([], _count, value, weight, _delta, c_acc, _q_acc) do
    [{value, weight}|c_acc]
    |> Enum.reverse
  end

  defp update_clusters([{v, _w}|_t]=clusters, _count, value, weight, _delta, _c_acc, 0)
    when v > value do
    [{value,weight}|clusters]
  end

  defp update_clusters([{v1, w1} = c1, {v2, w2} = c2|t], count, value, weight, delta, c_acc, q_acc)
    when v1 <= value and value <= v2 do
    case {value - v1, v2 - value} do
      {d1, d2} when d1 < d2 -> # closer to first centroid
        q = (q_acc + w1 / 2) / count
        lim = Enum.max([1, trunc(4 * count * delta * q * (1-q))])
        new_clusters = cluster_add(c1, value, weight, lim)
        Enum.reverse(c_acc) ++ new_clusters ++ [c2|t]
      {_d1, _d2} -> # d2 is smaller
        q = (q_acc + w1 + w2 / 2) / count
        lim = Enum.max([1, trunc(4 * count * delta * q * (1-q))])
        new_clusters = cluster_add(c2, value, weight, lim)
        Enum.reverse(c_acc) ++ [c1] ++ new_clusters ++ t
    end
  end

  defp update_clusters([{_v, w} = h|t], count, value, weight, delta, c_acc, q_acc) do
    update_clusters(t, count, value, weight, delta, [h|c_acc], q_acc + w)
  end

  defp cluster_add({v, w}, v, weight, _limit), do: [{v, w + weight}]
  defp cluster_add({v, w}, value, weight, limit) when w + weight <= limit do
    new_v = (v * w + value * weight) / (w + weight)
    [{new_v, w + weight}]
  end

  defp cluster_add({v, w}, value, weight, limit) do
    rem = w - Enum.max([0, limit - weight])
    used = weight - rem
    new_v = (v * w + value * used) / (w + used)
    [{value, rem}, {new_v, w + used}]
    |> Enum.sort
  end

  defp do_percentile(_, bad_p, _, _) when bad_p < 0 or bad_p > 1, do: raise("percentile #{bad_p} not in [0,1]")
  defp do_percentile([{v, _w}|_rest], 0, _count, _acc), do: v
  defp do_percentile(list, 1, _count, _acc), do: do_percentile(Enum.reverse(list), 0, 0, 0)
  defp do_percentile(_, _, 0, _), do: nil
  defp do_percentile([{v, _w}], _p, _count, _acc), do: v
  defp do_percentile([{v1, w1}, {v2, w2}|rest], p, count, acc) do
    q1 = (acc + w1 / 2) / count
    q2 = (acc + w1 + w2 / 2) / count
    cond do
      p < q1 -> v1
      q1 < p and p < q2 ->
        (v2 - v1) / (q2 - q1) * (p - q1) + v1
      true ->
        do_percentile([{v2, w2}|rest], p, count, acc + w1)
    end
  end

  defp do_quantile(_, _, 0, _), do: 0.0
  defp do_quantile([], _value, count, acc), do: acc / count
  defp do_quantile([{v, _w}|_t], value, _count, 0) when value < v, do: 0
  defp do_quantile([{v1, w1}, {v2, w2}|_t], value, count, acc) when v1 <= value and value <= v2 do
    q1 = (acc + w1 / 2) / count
    q2 = (acc + w1 + w2 / 2) / count
    (q2 - q1) / (v2 - v1) * (value - v1) + q1
  end

  defp do_quantile([{_v, w}|t], value, count, acc), do: do_quantile(t, value, count, acc + w)

  defp round_count(%{count: count} = digest), do: %{digest | count: round(count)}

  defp maybe_compress(%{autocompress_threshold: autocompress_threshold, clusters: clusters} = digest)
    when autocompress_threshold != nil and length(clusters) > autocompress_threshold
  do
    compress(digest)
  end

  defp maybe_compress(digest), do: digest

  defimpl Inspect, for: __MODULE__ do
    import Inspect.Algebra
    @inspect_ptiles [0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99]
    def inspect(%{count: count, clusters: clusters, delta: delta} = digest, opts) do
      pctiles = @inspect_ptiles
                |> Enum.map(&({:"p#{round(&1 * 100)}", TDigest.percentile(digest, &1)}))
      rep = [count: count, clusters: length(clusters), delta: delta] ++ pctiles
      concat ["#TDigest<", to_doc(rep, opts), ">" ]
    end
  end
end
