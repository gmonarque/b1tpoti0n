defmodule B1tpoti0n.Persistence.Schemas.User do
  @moduledoc """
  User schema for tracking passkeys and transfer statistics.

  ## Ratio & HnR Tracking

  - `hnr_warnings`: Count of hit-and-run warnings
  - `can_leech`: If false, user cannot download (ratio too low or too many HnRs)
  - `required_ratio`: Minimum ratio required for this user (0.0 = use global default)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          passkey: String.t() | nil,
          uploaded: integer(),
          downloaded: integer(),
          hnr_warnings: integer(),
          can_leech: boolean(),
          required_ratio: float(),
          bonus_points: float(),
          peers: [B1tpoti0n.Persistence.Schemas.Peer.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field :passkey, :string
    field :uploaded, :integer, default: 0
    field :downloaded, :integer, default: 0
    field :hnr_warnings, :integer, default: 0
    field :can_leech, :boolean, default: true
    field :required_ratio, :float, default: 0.0
    field :bonus_points, :float, default: 0.0

    has_many :peers, B1tpoti0n.Persistence.Schemas.Peer

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :passkey,
      :uploaded,
      :downloaded,
      :hnr_warnings,
      :can_leech,
      :required_ratio,
      :bonus_points
    ])
    |> validate_required([:passkey])
    |> validate_length(:passkey, is: 32)
    |> validate_number(:hnr_warnings, greater_than_or_equal_to: 0)
    |> validate_number(:required_ratio, greater_than_or_equal_to: 0.0)
    |> validate_number(:bonus_points, greater_than_or_equal_to: 0.0)
    |> unique_constraint(:passkey)
  end

  @doc "Generate a random 32-character passkey"
  def generate_passkey do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  @doc "Calculate user's current ratio (uploaded/downloaded)."
  @spec ratio(t()) :: float()
  def ratio(%__MODULE__{downloaded: 0}), do: :infinity
  def ratio(%__MODULE__{uploaded: up, downloaded: down}), do: up / down
end
