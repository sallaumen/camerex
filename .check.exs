[
  # sequencial: os testes despejam saída de ffmpeg/logs de crash esperados
  # e o relay paralelo do ex_check engasga com IO intercalado
  parallel: false,
  skipped: false,
  tools: [
    # defaults do ex_check cobrem compiler (-Werror), formatter, ex_unit,
    # dialyzer e unused_deps; só endurecemos o credo
    {:credo, "mix credo --strict"}
  ]
]
