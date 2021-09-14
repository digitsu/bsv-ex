defmodule BSV.PrivKey do
  @moduledoc """
  TODO
  """
  import BSV.Util, only: [decode: 2, encode: 2]

  defstruct d: nil, compressed: true

  @typedoc "TODO"
  @type t() :: %__MODULE__{
    d: privkey_bin(),
    compressed: boolean()
  }

  @typedoc "TODO"
  @type privkey_bin() :: <<_::256>> | privkey_hex()

  @typedoc "TODO"
  @type privkey_hex() :: String.t()

  @typedoc "TODO"
  @type privkey_wif() :: String.t()

  @version_bytes %{
    main: <<0x80>>,
    test: <<0xEF>>
  }

  @doc """
  TODO
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {_pubkey, privkey} = :crypto.generate_key(:ecdh, :secp256k1)
    from_binary(privkey, opts)
  end

  @doc """
  TODO
  """
  @spec from_binary(privkey_bin(), keyword()) :: t()
  def from_binary(privkey, opts \\ []) when is_binary(privkey) do
    encoding = Keyword.get(opts, :encoding)
    compressed = Keyword.get(opts, :compressed, true)

    case decode(privkey, encoding) do
      <<d::binary-32>> ->
        struct(__MODULE__, d: d, compressed: compressed)
      _ ->
        raise ArgumentError, "Invalid privkey"
    end
  end

  @doc """
  TODO
  """
  @spec from_wif(privkey_wif()) :: t()
  def from_wif(wif) when is_binary(wif) do
    version_byte = @version_bytes[BSV.network()]

    case B58.decode58_check!(wif) do
      {<<d::binary-32, 1>>, ^version_byte} ->
        struct(__MODULE__, d: d, compressed: true)

      {<<d::binary-32>>, ^version_byte} ->
        struct(__MODULE__, d: d, compressed: false)

      {<<_d::binary-32>>, version_byte} ->
        raise ArgumentError, "Invalid version byte #{ version_byte } for network: #{ BSV.network() }"

      _result ->
        raise ArgumentError, "Invalid WIF key"
    end
  end

  @doc """
  TODO
  """
  @spec to_binary(t()) :: privkey_bin()
  def to_binary(%__MODULE__{d: d}, opts \\ []) do
    encoding = Keyword.get(opts, :encoding)
    encode(d, encoding)
  end

  @doc """
  TODO
  """
  @spec to_wif(t()) :: privkey_wif()
  def to_wif(%__MODULE__{d: d, compressed: compressed}) do
    version_byte = @version_bytes[BSV.network()]
    privkey_with_suffix = case compressed do
      true -> <<d::binary, 0x01>>
      false -> d
    end

    B58.encode58_check!(privkey_with_suffix, version_byte)
  end

end
