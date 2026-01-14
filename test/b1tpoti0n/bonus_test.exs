defmodule B1tpoti0n.BonusTest do
  @moduledoc """
  Tests for Phase 3.6: Bonus Points System.
  """
  use B1tpoti0n.DataCase, async: false

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.User
  alias B1tpoti0n.Bonus.Calculator

  describe "Bonus Calculator" do
    setup do
      # Allow the Calculator GenServer to access the sandbox
      case Process.whereis(Calculator) do
        nil -> :ok
        pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
      end

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        Repo.insert(%User{
          passkey: User.generate_passkey(),
          uploaded: 0,
          downloaded: 0,
          hnr_warnings: 0,
          can_leech: true,
          required_ratio: 0.0,
          bonus_points: 0.0,
          inserted_at: now,
          updated_at: now
        })

      %{user: user}
    end

    test "get_points returns user's bonus points", %{user: user} do
      assert {:ok, points} = Calculator.get_points(user.id)
      assert points == 0.0
    end

    test "get_points returns error for non-existent user" do
      assert {:error, :not_found} = Calculator.get_points(999_999)
    end

    test "add_points increases user's bonus points", %{user: user} do
      assert :ok = Calculator.add_points(user.id, 10.0)
      assert {:ok, 10.0} = Calculator.get_points(user.id)

      assert :ok = Calculator.add_points(user.id, 5.5)
      assert {:ok, 15.5} = Calculator.get_points(user.id)
    end

    test "add_points returns error for non-existent user" do
      assert {:error, :not_found} = Calculator.add_points(999_999, 10.0)
    end

    test "remove_points decreases user's bonus points", %{user: user} do
      :ok = Calculator.add_points(user.id, 20.0)

      assert :ok = Calculator.remove_points(user.id, 5.0)
      assert {:ok, 15.0} = Calculator.get_points(user.id)
    end

    test "remove_points returns error when insufficient points", %{user: user} do
      :ok = Calculator.add_points(user.id, 10.0)

      assert {:error, :insufficient_points} = Calculator.remove_points(user.id, 15.0)
      # Points should remain unchanged
      assert {:ok, 10.0} = Calculator.get_points(user.id)
    end

    test "remove_points returns error for non-existent user" do
      assert {:error, :not_found} = Calculator.remove_points(999_999, 5.0)
    end

    test "redeem_points converts points to upload credit", %{user: user} do
      :ok = Calculator.add_points(user.id, 10.0)

      # Default conversion rate is 1GB per point
      assert {:ok, upload_credit} = Calculator.redeem_points(user.id, 5.0)
      # 5 GB
      assert upload_credit == 5_000_000_000

      # Check points were deducted
      assert {:ok, 5.0} = Calculator.get_points(user.id)

      # Check upload was credited
      updated_user = Repo.get!(User, user.id)
      assert updated_user.uploaded == 5_000_000_000
    end

    test "redeem_points with custom conversion rate", %{user: user} do
      :ok = Calculator.add_points(user.id, 10.0)

      # 500MB per point
      assert {:ok, upload_credit} = Calculator.redeem_points(user.id, 2.0, 500_000_000)
      # 1 GB
      assert upload_credit == 1_000_000_000
    end

    test "redeem_points returns error when insufficient points", %{user: user} do
      :ok = Calculator.add_points(user.id, 5.0)

      assert {:error, :insufficient_points} = Calculator.redeem_points(user.id, 10.0)
    end

    test "redeem_points returns error for non-existent user" do
      assert {:error, :not_found} = Calculator.redeem_points(999_999, 5.0)
    end

    test "stats returns calculator configuration" do
      stats = Calculator.stats()

      assert Map.has_key?(stats, :enabled)
      assert Map.has_key?(stats, :base_points)
      assert Map.has_key?(stats, :last_calculation)
    end
  end

  describe "User schema bonus_points field" do
    test "bonus_points defaults to 0.0" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        Repo.insert(%User{
          passkey: User.generate_passkey(),
          uploaded: 0,
          downloaded: 0,
          inserted_at: now,
          updated_at: now
        })

      assert user.bonus_points == 0.0
    end

    test "bonus_points can be updated via changeset" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        Repo.insert(%User{
          passkey: User.generate_passkey(),
          uploaded: 0,
          downloaded: 0,
          bonus_points: 0.0,
          inserted_at: now,
          updated_at: now
        })

      {:ok, updated} =
        user
        |> User.changeset(%{bonus_points: 42.5})
        |> Repo.update()

      assert updated.bonus_points == 42.5
    end

    test "bonus_points cannot be negative" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, user} =
        Repo.insert(%User{
          passkey: User.generate_passkey(),
          uploaded: 0,
          downloaded: 0,
          bonus_points: 10.0,
          inserted_at: now,
          updated_at: now
        })

      changeset = User.changeset(user, %{bonus_points: -5.0})
      assert {:error, _changeset} = Repo.update(changeset)
    end
  end
end
