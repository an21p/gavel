%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/"], excluded: []},
      strict: true,
      checks: %{disabled: [{Credo.Check.Readability.ModuleDoc, []}]}
    }
  ]
}
