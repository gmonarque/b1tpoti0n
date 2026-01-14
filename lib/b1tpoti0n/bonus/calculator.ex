defmodule B1tpoti0n.Bonus.Calculator do
  @moduledoc """
  Periodic bonus points calculator GenServer.

  Awards points to users based on their active seeding activity.
  More points are awarded for seeding rare torrents (fewer seeders, more leechers).

  ## Points Formula

      points_per_hour = base_points * sqrt(total_seeders) / max(1, leechers)

  - Seeding rare torrents (few seeders, many leechers) yields more points
  - Points are calculated hourly and accumulated
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.User
  alias B1tpoti0n.Swarm

  # Calculate points every hour
  @calc_interval :timer.hours(1)

  # Default base points per hour for seeding
  @default_base_points 1.0

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a points calculation.
  """
  @spec calculate_now() :: :ok
  def calculate_now do
    GenServer.cast(__MODULE__, :calculate)
  end

  @doc """
  Get current calculator statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Add bonus points to a user.
  """
  @spec add_points(integer(), float()) :: :ok | {:error, :not_found}
  def add_points(user_id, points) when points > 0 do
    GenServer.call(__MODULE__, {:add_points, user_id, points})
  end

  @doc """
  Remove bonus points from a user.
  """
  @spec remove_points(integer(), float()) :: :ok | {:error, :not_found | :insufficient_points}
  def remove_points(user_id, points) when points > 0 do
    GenServer.call(__MODULE__, {:remove_points, user_id, points})
  end

  @doc """
  Redeem bonus points for upload credit.

  ## Parameters
  - user_id: The user to credit
  - points: Points to redeem
  - conversion_rate: Bytes per point (default: 1GB per point)
  """
  @spec redeem_points(integer(), float(), integer()) :: {:ok, integer()} | {:error, atom()}
  def redeem_points(user_id, points, conversion_rate \\ 1_000_000_000) when points > 0 do
    GenServer.call(__MODULE__, {:redeem_points, user_id, points, conversion_rate})
  end

  @doc """
  Get bonus points for a user.
  """
  @spec get_points(integer()) :: {:ok, float()} | {:error, :not_found}
  def get_points(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :not_found}
      user -> {:ok, user.bonus_points}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    schedule_calculation()

    {:ok,
     %{
       last_calculation: nil,
       users_awarded: 0,
       total_points_awarded: 0.0
     }}
  end

  @impl true
  def handle_cast(:calculate, state) do
    new_state = run_calculation(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    config = Application.get_env(:b1tpoti0n, :bonus_points, [])

    stats = %{
      enabled: config != [],
      base_points: Keyword.get(config, :base_points, @default_base_points),
      last_calculation: state.last_calculation,
      users_awarded: state.users_awarded,
      total_points_awarded: state.total_points_awarded
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:add_points, user_id, points}, _from, state) do
    result =
      case Repo.get(User, user_id) do
        nil ->
          {:error, :not_found}

        user ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          new_points = user.bonus_points + points

          Repo.update_all(
            from(u in User, where: u.id == ^user_id),
            set: [bonus_points: new_points, updated_at: now]
          )

          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove_points, user_id, points}, _from, state) do
    result =
      case Repo.get(User, user_id) do
        nil ->
          {:error, :not_found}

        user when user.bonus_points < points ->
          {:error, :insufficient_points}

        user ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          new_points = user.bonus_points - points

          Repo.update_all(
            from(u in User, where: u.id == ^user_id),
            set: [bonus_points: new_points, updated_at: now]
          )

          :ok
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:redeem_points, user_id, points, conversion_rate}, _from, state) do
    result =
      case Repo.get(User, user_id) do
        nil ->
          {:error, :not_found}

        user when user.bonus_points < points ->
          {:error, :insufficient_points}

        user ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          new_points = user.bonus_points - points
          upload_credit = trunc(points * conversion_rate)
          new_uploaded = user.uploaded + upload_credit

          Repo.update_all(
            from(u in User, where: u.id == ^user_id),
            set: [bonus_points: new_points, uploaded: new_uploaded, updated_at: now]
          )

          {:ok, upload_credit}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info(:calculate, state) do
    new_state = run_calculation(state)
    schedule_calculation()
    {:noreply, new_state}
  end

  # Private

  defp schedule_calculation do
    Process.send_after(self(), :calculate, @calc_interval)
  end

  defp run_calculation(state) do
    config = Application.get_env(:b1tpoti0n, :bonus_points, [])

    if config == [] do
      # Bonus points disabled
      state
    else
      base_points = Keyword.get(config, :base_points, @default_base_points)

      Logger.info("Running bonus points calculation (base_points=#{base_points})")

      # Get all active swarm workers
      swarm_workers = Swarm.list_workers()

      # For each swarm, calculate points for seeders
      points_by_user =
        Enum.reduce(swarm_workers, %{}, fn {_info_hash, pid}, acc ->
          try do
            # Get swarm stats
            {seeders, _completed, leechers} = Swarm.Worker.get_stats(pid)

            # Get the list of peers to find seeders
            peers = Swarm.Worker.get_peers(pid, 1000)

            # Calculate points for this torrent
            # More points for fewer seeders and more leechers (rare torrents)
            points =
              if seeders > 0 do
                base_points * :math.sqrt(seeders) / max(1, leechers)
              else
                0.0
              end

            # Award points to each seeder
            Enum.reduce(peers, acc, fn peer, inner_acc ->
              if peer.is_seeder and peer.user_id do
                Map.update(inner_acc, peer.user_id, points, &(&1 + points))
              else
                inner_acc
              end
            end)
          rescue
            _ -> acc
          catch
            :exit, _ -> acc
          end
        end)

      # Update user bonus points in DB
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      users_awarded = map_size(points_by_user)

      total_points_awarded =
        Enum.reduce(points_by_user, 0.0, fn {user_id, points}, total ->
          Repo.update_all(
            from(u in User, where: u.id == ^user_id),
            inc: [bonus_points: points],
            set: [updated_at: now]
          )

          total + points
        end)

      if users_awarded > 0 do
        Logger.info(
          "Bonus points awarded: #{users_awarded} users, #{Float.round(total_points_awarded, 2)} total points"
        )
      end

      %{
        state
        | last_calculation: DateTime.utc_now(),
          users_awarded: users_awarded,
          total_points_awarded: total_points_awarded
      }
    end
  end
end
