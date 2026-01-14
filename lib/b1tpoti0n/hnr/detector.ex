defmodule B1tpoti0n.Hnr.Detector do
  @moduledoc """
  Hit-and-Run detection GenServer.

  Periodically checks snatches that have passed their grace period and
  marks them as HnR if they haven't met the minimum seedtime requirement.
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.{Snatch, User}

  # Check for HnRs every 6 hours
  @check_interval :timer.hours(6)

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger an HnR check.
  """
  @spec check_now() :: :ok
  def check_now do
    GenServer.cast(__MODULE__, :check)
  end

  @doc """
  Get HnR statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Clear HnR status for a specific snatch.
  """
  @spec clear_hnr(integer()) :: :ok | {:error, :not_found}
  def clear_hnr(snatch_id) do
    GenServer.call(__MODULE__, {:clear_hnr, snatch_id})
  end

  @doc """
  Clear all HnR warnings for a user.
  """
  @spec clear_user_warnings(integer()) :: :ok | {:error, :not_found}
  def clear_user_warnings(user_id) do
    GenServer.call(__MODULE__, {:clear_user_warnings, user_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    schedule_check()

    {:ok,
     %{
       last_check: nil,
       hnr_count: 0,
       warnings_issued: 0
     }}
  end

  @impl true
  def handle_cast(:check, state) do
    new_state = run_hnr_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    hnr_config = Application.get_env(:b1tpoti0n, :hnr)

    stats = %{
      enabled: not is_nil(hnr_config),
      last_check: state.last_check,
      hnr_count: state.hnr_count,
      warnings_issued: state.warnings_issued,
      config: hnr_config
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:clear_hnr, snatch_id}, _from, state) do
    result =
      case Repo.get(Snatch, snatch_id) do
        nil ->
          {:error, :not_found}

        snatch ->
          snatch
          |> Snatch.changeset(%{hnr: false})
          |> Repo.update()

          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:clear_user_warnings, user_id}, _from, state) do
    result =
      case Repo.get(User, user_id) do
        nil ->
          {:error, :not_found}

        user ->
          user
          |> User.changeset(%{hnr_warnings: 0, can_leech: true})
          |> Repo.update()

          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = run_hnr_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  # Private

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval)
  end

  defp run_hnr_check(state) do
    hnr_config = Application.get_env(:b1tpoti0n, :hnr)

    if is_nil(hnr_config) do
      # HnR checking disabled
      state
    else
      min_seedtime = Keyword.get(hnr_config, :min_seedtime, 72 * 3600)
      grace_period_days = Keyword.get(hnr_config, :grace_period_days, 14)
      max_warnings = Keyword.get(hnr_config, :max_warnings, 3)

      Logger.info(
        "Running HnR check (min_seedtime=#{min_seedtime}s, grace=#{grace_period_days}d)"
      )

      # Find snatches that:
      # 1. Are past grace period
      # 2. Haven't met seedtime requirement
      # 3. Aren't already marked as HnR
      grace_cutoff =
        DateTime.utc_now()
        |> DateTime.add(-grace_period_days * 86400, :second)

      potential_hnrs =
        from(s in Snatch,
          where: s.completed_at < ^grace_cutoff,
          where: s.seedtime < ^min_seedtime,
          where: s.hnr == false,
          preload: [:user]
        )
        |> Repo.all()

      hnr_count = length(potential_hnrs)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Process each potential HnR
      warnings_by_user =
        Enum.reduce(potential_hnrs, %{}, fn snatch, acc ->
          # Mark as HnR
          Repo.update_all(
            from(s in Snatch, where: s.id == ^snatch.id),
            set: [hnr: true, updated_at: now]
          )

          # Count warnings per user
          Map.update(acc, snatch.user_id, 1, &(&1 + 1))
        end)

      # Update user warning counts
      Enum.each(warnings_by_user, fn {user_id, new_warnings} ->
        # Increment warnings and potentially disable leeching
        case Repo.get(User, user_id) do
          nil ->
            :ok

          user ->
            total_warnings = user.hnr_warnings + new_warnings
            can_leech = total_warnings < max_warnings

            Repo.update_all(
              from(u in User, where: u.id == ^user_id),
              set: [hnr_warnings: total_warnings, can_leech: can_leech, updated_at: now]
            )

            if not can_leech do
              Logger.warning(
                "User #{user_id} disabled for leeching due to #{total_warnings} HnR warnings"
              )
            end
        end
      end)

      warnings_issued = Enum.reduce(warnings_by_user, 0, fn {_, w}, acc -> acc + w end)

      if hnr_count > 0 do
        Logger.info(
          "HnR check complete: #{hnr_count} new HnRs, #{warnings_issued} warnings issued"
        )
      end

      %{
        state
        | last_check: DateTime.utc_now(),
          hnr_count: hnr_count,
          warnings_issued: warnings_issued
      }
    end
  end
end
