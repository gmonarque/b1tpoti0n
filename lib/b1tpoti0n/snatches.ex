defmodule B1tpoti0n.Snatches do
  @moduledoc """
  Context for managing snatch records (torrent completions).

  Tracks when users complete downloading torrents and their seedtime after completion.
  Used for hit-and-run detection.
  """
  import Ecto.Query
  require Logger

  alias B1tpoti0n.Persistence.Repo
  alias B1tpoti0n.Persistence.Schemas.Snatch

  @doc """
  Record a snatch (completion) for a user and torrent.
  If a snatch already exists, this is a no-op (idempotent).
  """
  @spec record_snatch(integer(), integer()) :: {:ok, Snatch.t()} | {:error, term()}
  def record_snatch(user_id, torrent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs = %{
      user_id: user_id,
      torrent_id: torrent_id,
      completed_at: now,
      last_announce_at: now,
      seedtime: 0
    }

    %Snatch{}
    |> Snatch.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, snatch} ->
        Logger.debug("Recorded snatch: user_id=#{user_id}, torrent_id=#{torrent_id}")
        {:ok, snatch}

      {:error, changeset} ->
        # Check if it's a unique constraint violation (already snatched)
        if has_error?(changeset, :user_id, "has already been taken") do
          # Return existing snatch
          {:ok, get_snatch(user_id, torrent_id)}
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  Update seedtime for a snatch based on time since last announce.
  Called on each seeding announce (left = 0).
  """
  @spec update_seedtime(integer(), integer()) :: :ok
  def update_seedtime(user_id, torrent_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_snatch(user_id, torrent_id) do
      nil ->
        # No snatch record, nothing to update
        :ok

      snatch ->
        # Calculate time since last announce
        delta_seconds =
          if snatch.last_announce_at do
            DateTime.diff(now, snatch.last_announce_at, :second)
            |> max(0)
            # Cap at 2 hours to prevent abuse
            |> min(7200)
          else
            0
          end

        # Update seedtime and last_announce_at
        Repo.update_all(
          from(s in Snatch, where: s.id == ^snatch.id),
          set: [last_announce_at: now, updated_at: now],
          inc: [seedtime: delta_seconds]
        )

        :ok
    end
  end

  @doc """
  Get a snatch record by user and torrent.
  """
  @spec get_snatch(integer(), integer()) :: Snatch.t() | nil
  def get_snatch(user_id, torrent_id) do
    Repo.get_by(Snatch, user_id: user_id, torrent_id: torrent_id)
  end

  @doc """
  Get a snatch by ID.
  """
  @spec get_snatch_by_id(integer()) :: Snatch.t() | nil
  def get_snatch_by_id(id) do
    Repo.get(Snatch, id)
    |> Repo.preload([:user, :torrent])
  end

  @doc """
  Delete a snatch record.
  """
  @spec delete_snatch(integer()) :: {:ok, Snatch.t()} | {:error, :not_found}
  def delete_snatch(id) do
    case Repo.get(Snatch, id) do
      nil -> {:error, :not_found}
      snatch -> Repo.delete(snatch)
    end
  end

  @doc """
  Update a snatch record. Used for admin corrections.

  ## Options
  - `:seedtime` - Set seedtime (seconds)
  - `:hnr` - Set HnR flag (boolean)
  """
  @spec update_snatch(integer(), keyword()) ::
          {:ok, Snatch.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_snatch(id, opts) do
    case Repo.get(Snatch, id) do
      nil ->
        {:error, :not_found}

      snatch ->
        changes =
          opts
          |> Keyword.take([:seedtime, :hnr])
          |> Map.new()

        snatch
        |> Snatch.changeset(changes)
        |> Repo.update()
    end
  end

  @doc """
  Clear HnR flag for a snatch.
  """
  @spec clear_hnr(integer()) :: {:ok, Snatch.t()} | {:error, :not_found}
  def clear_hnr(snatch_id) do
    update_snatch(snatch_id, hnr: false)
  end

  @doc """
  List all snatches marked as HnR.
  """
  @spec list_hnr_snatches() :: [Snatch.t()]
  def list_hnr_snatches do
    from(s in Snatch,
      where: s.hnr == true,
      order_by: [desc: s.completed_at],
      preload: [:user, :torrent]
    )
    |> Repo.all()
  end

  @doc """
  Get all snatches for a user.
  """
  @spec list_user_snatches(integer()) :: [Snatch.t()]
  def list_user_snatches(user_id) do
    from(s in Snatch,
      where: s.user_id == ^user_id,
      order_by: [desc: s.completed_at],
      preload: [:torrent]
    )
    |> Repo.all()
  end

  @doc """
  Get all snatches for a torrent.
  """
  @spec list_torrent_snatches(integer()) :: [Snatch.t()]
  def list_torrent_snatches(torrent_id) do
    from(s in Snatch,
      where: s.torrent_id == ^torrent_id,
      order_by: [desc: s.completed_at],
      preload: [:user]
    )
    |> Repo.all()
  end

  @doc """
  Get snatch count for a torrent.
  """
  @spec count_torrent_snatches(integer()) :: non_neg_integer()
  def count_torrent_snatches(torrent_id) do
    from(s in Snatch, where: s.torrent_id == ^torrent_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Get snatches that need HnR checking (completed but not meeting requirements).
  """
  @spec list_potential_hnr(non_neg_integer(), non_neg_integer()) :: [Snatch.t()]
  def list_potential_hnr(min_seedtime, grace_period_days) do
    grace_cutoff =
      DateTime.utc_now()
      |> DateTime.add(-grace_period_days * 86400, :second)

    from(s in Snatch,
      where: s.completed_at < ^grace_cutoff,
      where: s.seedtime < ^min_seedtime,
      preload: [:user, :torrent]
    )
    |> Repo.all()
  end

  # Private helpers

  defp has_error?(changeset, field, message) do
    Enum.any?(changeset.errors, fn {f, {msg, _}} ->
      f == field and String.contains?(msg, message)
    end)
  end
end
