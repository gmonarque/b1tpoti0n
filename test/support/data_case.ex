defmodule B1tpoti0n.DataCase do
  @moduledoc """
  Test case template for tests requiring database access.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias B1tpoti0n.Persistence.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import B1tpoti0n.DataCase
    end
  end

  setup tags do
    B1tpoti0n.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid =
      Ecto.Adapters.SQL.Sandbox.start_owner!(B1tpoti0n.Persistence.Repo, shared: not tags[:async])

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  Create a test user with a random passkey.
  """
  def create_user(attrs \\ %{}) do
    passkey = Map.get(attrs, :passkey, random_passkey())

    {:ok, user} =
      %B1tpoti0n.Persistence.Schemas.User{}
      |> B1tpoti0n.Persistence.Schemas.User.changeset(%{passkey: passkey})
      |> B1tpoti0n.Persistence.Repo.insert()

    user
  end

  @doc """
  Generate a random 32-character passkey.
  """
  def random_passkey do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc """
  Generate a random 20-byte info_hash.
  """
  def random_info_hash do
    :crypto.strong_rand_bytes(20)
  end
end
