defmodule Camerex.DoctorStub do
  @moduledoc "Dublê do Doctor para testes (config :camerex, :doctor)."

  def check do
    Application.get_env(:camerex, :doctor_result, %{ffmpeg: :ok, models: :ok})
  end
end
