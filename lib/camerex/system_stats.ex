defmodule Camerex.SystemStats do
  @moduledoc """
  Telemetria leve da máquina para o mini-dashboard de performance: CPU do
  sistema (via `:cpu_sup`), RAM do sistema (via `:memsup`) e memória do BEAM.

  Depende de `:os_mon` (em `extra_applications`). `snapshot/0` é barato e
  **à prova de falha**: se uma porta do os_mon hesitar, o campo vira `nil` em
  vez de derrubar a página — o dashboard só mostra "—" naquele número.

  `:cpu_sup.util/0` mede a utilização desde a chamada anterior, então chamá-lo
  a cada tick do dashboard dá a média do intervalo (a 1ª leitura é desde o boot).
  """

  @mib 1_048_576

  @type t :: %{
          cpu_pct: non_neg_integer() | nil,
          mem:
            %{used_mb: non_neg_integer(), total_mb: non_neg_integer(), pct: non_neg_integer()}
            | nil,
          beam_mb: non_neg_integer(),
          schedulers: pos_integer()
        }

  @spec snapshot() :: t()
  def snapshot do
    %{
      cpu_pct: cpu_pct(),
      mem: mem(),
      beam_mb: div(:erlang.memory(:total), @mib),
      schedulers: System.schedulers_online()
    }
  end

  defp cpu_pct do
    case safe(fn -> :cpu_sup.util() end) do
      n when is_number(n) -> n |> round() |> max(0) |> min(100)
      _ -> nil
    end
  end

  defp mem do
    with data when is_list(data) <- safe(fn -> :memsup.get_system_memory_data() end),
         total when is_integer(total) and total > 0 <-
           data[:system_total_memory] || data[:total_memory],
         avail when is_integer(avail) <- data[:available_memory] || data[:free_memory] do
      used = max(total - avail, 0)
      %{used_mb: div(used, @mib), total_mb: div(total, @mib), pct: round(used * 100 / total)}
    else
      _ -> nil
    end
  end

  # os_mon roda em portas externas; uma falha pontual não pode estourar a página
  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
