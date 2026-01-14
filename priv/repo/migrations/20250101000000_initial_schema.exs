defmodule B1tpoti0n.Persistence.Repo.Migrations.InitialSchema do
  use Ecto.Migration

  def change do
    # Users table
    create table(:users) do
      add(:passkey, :string, null: false, size: 32)
      add(:uploaded, :bigint, default: 0, null: false)
      add(:downloaded, :bigint, default: 0, null: false)
      add(:hnr_warnings, :integer, default: 0, null: false)
      add(:can_leech, :boolean, default: true, null: false)
      add(:required_ratio, :float, default: 0.0, null: false)
      add(:bonus_points, :float, default: 0.0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:users, [:passkey]))

    # Torrents table
    create table(:torrents) do
      add(:info_hash, :binary, null: false, size: 20)
      add(:seeders, :integer, default: 0, null: false)
      add(:leechers, :integer, default: 0, null: false)
      add(:completed, :integer, default: 0, null: false)
      add(:freeleech, :boolean, default: false, null: false)
      add(:freeleech_until, :utc_datetime)
      add(:upload_multiplier, :float, default: 1.0, null: false)
      add(:download_multiplier, :float, default: 1.0, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:torrents, [:info_hash]))

    # Peers table
    create table(:peers, primary_key: false) do
      add(:user_id, references(:users, on_delete: :delete_all), primary_key: true)
      add(:torrent_id, references(:torrents, on_delete: :delete_all), primary_key: true)

      add(:ip, :string, null: false)
      add(:port, :integer, null: false)
      add(:peer_id, :binary, size: 20)
      add(:left, :bigint)
      add(:uploaded, :bigint, default: 0, null: false)
      add(:downloaded, :bigint, default: 0, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:peers, [:torrent_id]))
    create(index(:peers, [:user_id]))

    # Whitelist table
    create table(:whitelist) do
      add(:client_prefix, :string, null: false, size: 8)
      add(:name, :string, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:whitelist, [:client_prefix]))

    # Banned IPs table
    create table(:banned_ips) do
      add(:ip, :string, null: false)
      add(:reason, :string, null: false)
      add(:expires_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:banned_ips, [:ip]))
    create(index(:banned_ips, [:expires_at]))

    # Snatches table
    create table(:snatches) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:torrent_id, references(:torrents, on_delete: :delete_all), null: false)
      add(:completed_at, :utc_datetime, null: false)
      add(:seedtime, :integer, default: 0, null: false)
      add(:last_announce_at, :utc_datetime)
      add(:hnr, :boolean, default: false, null: false)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:snatches, [:user_id, :torrent_id]))
    create(index(:snatches, [:user_id]))
    create(index(:snatches, [:torrent_id]))
    create(index(:snatches, [:hnr], where: "hnr = true"))
  end
end
