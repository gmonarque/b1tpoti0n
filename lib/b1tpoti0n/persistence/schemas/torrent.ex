defmodule B1tpoti0n.Persistence.Schemas.Torrent do
  @moduledoc """
  Torrent schema for tracking torrents and their statistics.

  ## Freeleech & Multipliers

  - `freeleech`: If true, downloads don't count against user's ratio
  - `freeleech_until`: Optional expiry time for timed freeleech
  - `upload_multiplier`: Multiplier for upload credit (e.g., 2.0 = double upload)
  - `download_multiplier`: Multiplier for download charge (e.g., 0.5 = half download)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          info_hash: binary() | nil,
          seeders: integer(),
          leechers: integer(),
          completed: integer(),
          freeleech: boolean(),
          freeleech_until: DateTime.t() | nil,
          upload_multiplier: float(),
          download_multiplier: float(),
          peers: [B1tpoti0n.Persistence.Schemas.Peer.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "torrents" do
    field :info_hash, :binary
    field :seeders, :integer, default: 0
    field :leechers, :integer, default: 0
    field :completed, :integer, default: 0
    field :freeleech, :boolean, default: false
    field :freeleech_until, :utc_datetime
    field :upload_multiplier, :float, default: 1.0
    field :download_multiplier, :float, default: 1.0

    has_many :peers, B1tpoti0n.Persistence.Schemas.Peer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(torrent, attrs) do
    torrent
    |> cast(attrs, [
      :info_hash,
      :seeders,
      :leechers,
      :completed,
      :freeleech,
      :freeleech_until,
      :upload_multiplier,
      :download_multiplier
    ])
    |> validate_required([:info_hash])
    |> validate_info_hash_size()
    # Cap multipliers to prevent abuse (max 10x seems reasonable)
    |> validate_number(:upload_multiplier,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 10.0
    )
    |> validate_number(:download_multiplier,
      greater_than_or_equal_to: 0.0,
      less_than_or_equal_to: 10.0
    )
    |> unique_constraint(:info_hash)
  end

  defp validate_info_hash_size(changeset) do
    validate_change(changeset, :info_hash, fn :info_hash, info_hash ->
      if byte_size(info_hash) == 20 do
        []
      else
        [info_hash: "must be exactly 20 bytes"]
      end
    end)
  end

  @doc "Convert info_hash binary to hex string for display"
  def info_hash_hex(%__MODULE__{info_hash: hash}) when is_binary(hash) do
    Base.encode16(hash, case: :lower)
  end

  @doc """
  Check if freeleech is currently active for this torrent.
  Returns true if freeleech is enabled and not expired.
  """
  @spec freeleech_active?(t()) :: boolean()
  def freeleech_active?(%__MODULE__{freeleech: false}), do: false

  def freeleech_active?(%__MODULE__{freeleech: true, freeleech_until: nil}), do: true

  def freeleech_active?(%__MODULE__{freeleech: true, freeleech_until: until}) do
    DateTime.compare(DateTime.utc_now(), until) == :lt
  end

  @doc """
  Get the effective download multiplier (0.0 if freeleech is active).
  """
  @spec effective_download_multiplier(t()) :: float()
  def effective_download_multiplier(torrent) do
    if freeleech_active?(torrent), do: 0.0, else: torrent.download_multiplier
  end
end
