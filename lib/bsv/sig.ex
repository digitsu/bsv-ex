defmodule BSV.Sig do
  @moduledoc """
  Module for signing and verifying Bitcoin transactions.

  Signing a transaction in Bitcoin first involves computing a transaction
  preimage. A `t:BSV.Sig.sighash_flag/0` is used to indicate which parts of the
  transaction are included in the preimage.

  | Flag                            | Value with SIGHASH_FORKID | Value without SIGHASH_FORKID | Description                         |
  | ------------------------------- | ------------------------- | ---------------------------- | ----------------------------------- |
  | `SIGHASH_ALL`                   | `0x41` / `0100 0001`      | `0x01` / `0000 0001`         | Sign all inputs and outputs         |
  | `SIGHASH_NONE`                  | `0x42` / `0100 0010`      | `0x02` / `0000 0010`         | Sign all inputs and no outputs      |
  | `SIGHASH_SINGLE`                | `0x43` / `0100 0011`      | `0x03` / `0000 0011`         | Sign all inputs and single output   |
  | `SIGHASH_ALL | ANYONECANPAY`    | `0xC1` / `1100 0001`      | `0x81` / `1000 0001`         | Sign single input and all outputs   |
  | `SIGHASH_NONE | ANYONECANPAY`   | `0xC2` / `1100 0010`      | `0x82` / `1000 0010`         | Sign single input and no outputs    |
  | `SIGHASH_SINGLE | ANYONECANPAY` | `0xC3` / `1100 0011`      | `0x83` / `1000 0011`         | Sign single input and single output |

  Once the preimage is constructed, it is double hashed using the `SHA-256`
  algorithm and then used to calculate the ECDSA signature. The resulting
  DER-encoded signature is appended with the sighash flag.
  """
  use Bitwise
  alias BSV.{Hash, OutPoint, PrivKey, PubKey, Script, Tx, TxIn, TxOut, VarInt}

  @typedoc "Sighash preimage"
  @type preimage() :: binary()

  @typedoc "Sighash"
  @type sighash() :: <<_::256>>

  @typedoc "Sighash flag"
  @type sighash_flag() :: integer()

  @typedoc """
  Signature

  DER-encoded signature with the sighash flag appended.
  """
  @type signature() :: binary()

  @sighash_all 0x01
  @sighash_none 0x02
  @sighash_single 0x03
  @sighash_forkid 0x40
  @sighash_anyonecanpay 0x80

  @default_sighash @sighash_all ||| @sighash_forkid

  defguard sighash_all?(sighash_flag)
           when (sighash_flag &&& 31) == @sighash_all

  defguard sighash_none?(sighash_flag)
           when (sighash_flag &&& 31) == @sighash_none

  defguard sighash_single?(sighash_flag)
           when (sighash_flag &&& 31) == @sighash_single

  defguard sighash_forkid?(sighash_flag)
           when (sighash_flag &&& @sighash_forkid) != 0

  defguard sighash_anyone_can_pay?(sighash_flag)
           when (sighash_flag &&& @sighash_anyonecanpay) != 0

  @doc """
  Returns the `t:BSV.Sig.sighash_flag/0` of the given sighash type.

  ## Examples

      iex> Sig.sighash_flag(:default)
      0x41
  """
  @spec sighash_flag(atom()) :: sighash_flag()
  def sighash_flag(sighash_type \\ :default)
  def sighash_flag(:default), do: @default_sighash
  def sighash_flag(:sighash_all), do: @sighash_all
  def sighash_flag(:sighash_none), do: @sighash_none
  def sighash_flag(:sighash_single), do: @sighash_single
  def sighash_flag(:sighash_forkid), do: @sighash_forkid
  def sighash_flag(:sighash_anyonecanpay), do: @sighash_anyonecanpay

  @doc """
  Returns the preimage for the given transaction. Must also specify the
  `t:BSV.TxIn.vin/0` of the context input, the `t:BSV.TxOut.t/0` that is being
  spent, and the `t:BSV.Sig.sighash_flag/0`.

  BSV transactions require the `SIGHASH_FORKID` flag which results in a preimage
  according the algorithm proposed in [BIP-143](https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki).
  The legacy preimage algorithm is supported by this library.
  """
  @spec preimage(Tx.t(), TxIn.vin(), TxOut.t(), sighash_flag()) :: preimage()
  def preimage(%Tx{inputs: inputs} = tx, vin, %TxOut{} = txout, sighash_type)
      when sighash_forkid?(sighash_type) do
    input = Enum.at(inputs, vin)

    # Input prevouts/nSequence
    prevouts_hash = hash_prevouts(tx.inputs, sighash_type)
    sequence_hash = hash_sequence(tx.inputs, sighash_type)

    # outpoint (32-byte hash + 4-byte little endian)
    outpoint = OutPoint.to_binary(input.outpoint)

    # subscript
    subscript =
      txout.script
      |> Script.to_binary()
      |> VarInt.encode_binary()

    # Outputs (none/one/all, depending on flags)
    outputs_hash = hash_outputs(tx.outputs, vin, sighash_type)

    <<
      tx.version::little-32,
      prevouts_hash::binary,
      sequence_hash::binary,
      outpoint::binary,
      subscript::binary,
      txout.satoshis::little-64,
      input.sequence::little-32,
      outputs_hash::binary,
      tx.lock_time::little-32,
      sighash_type >>> 0::little-32
    >>
  end

  def preimage(%Tx{} = tx, vin, %TxOut{} = txout, sighash_type) do
    %{script: subscript} =
      update_in(txout.script.chunks, fn chunks ->
        Enum.reject(chunks, &(&1 == :OP_CODESEPARATOR))
      end)

    tx = update_in(tx.inputs, &update_tx_inputs(&1, vin, subscript, sighash_type))
    tx = update_in(tx.outputs, &update_tx_outputs(&1, vin, sighash_type))

    Tx.to_binary(tx) <> <<sighash_type::little-32>>
  end

  @doc """
  Computes a double SHA256 hash of the preimage of the given transaction. Must
  also specify the `t:BSV.TxIn.vin/0` of the context input, the `t:BSV.TxOut.t/0`
  that is being spent, and the `t:BSV.Sig.sighash_flag/0`.
  """
  @spec sighash(Tx.t(), TxIn.vin(), TxOut.t(), sighash_flag()) :: sighash()
  def sighash(%Tx{} = tx, vin, %TxOut{} = txout, sighash_type \\ @default_sighash) do
    tx
    |> preimage(vin, txout, sighash_type)
    |> Hash.sha256_sha256()
  end

  @doc """
  Signs the sighash of the given transaction using the given PrivKey. Must also
  specify the `t:BSV.TxIn.vin/0` of the context input, the `t:BSV.TxOut.t/0`
  that is being spent, and the `t:BSV.Sig.sighash_flag/0`.

  The returned DER-encoded signature is appended with the sighash flag.
  """
  @spec sign(Tx.t(), TxIn.vin(), TxOut.t(), PrivKey.t(), keyword()) :: signature()
  def sign(%Tx{} = tx, vin, %TxOut{} = txout, %PrivKey{d: privkey}, opts \\ []) do
    sighash_type = Keyword.get(opts, :sighash_type, @default_sighash)

    tx
    |> sighash(vin, txout, sighash_type)
    |> Curvy.sign(privkey, hash: false)
    |> Kernel.<>(<<sighash_type>>)
  end

  @doc """
  Verifies the signature against the sighash of the given transaction using the
  specified PubKey. Must also specify the `t:BSV.TxIn.vin/0` of the context
  input, the `t:BSV.TxOut.t/0` that is being spent.
  """
  @spec verify(signature(), Tx.t(), TxIn.vin(), TxOut.t(), PubKey.t()) :: boolean() | :error
  def verify(signature, %Tx{} = tx, vin, %TxOut{} = txout, %PubKey{} = pubkey) do
    sig_length = byte_size(signature) - 1
    <<sig::binary-size(sig_length), sighash_type>> = signature
    message = sighash(tx, vin, txout, sighash_type)
    Curvy.verify(sig, message, PubKey.to_binary(pubkey), hash: false)
  end

  # Double hashes the outpoints of the transaction inputs
  defp hash_prevouts(_inputs, sighash_type)
       when sighash_anyone_can_pay?(sighash_type),
       do: <<0::256>>

  defp hash_prevouts(inputs, _sighash_type) do
    inputs
    |> Enum.reduce(<<>>, &(&2 <> OutPoint.to_binary(&1.outpoint)))
    |> Hash.sha256_sha256()
  end

  # Double hashes the sequence values of the transaction inputs
  defp hash_sequence(_inputs, sighash_type)
       when sighash_anyone_can_pay?(sighash_type) or
              sighash_single?(sighash_type) or
              sighash_none?(sighash_type),
       do: <<0::256>>

  defp hash_sequence(inputs, _sighash_type) do
    inputs
    |> Enum.reduce(<<>>, &(&2 <> <<&1.sequence::little-32>>))
    |> Hash.sha256_sha256()
  end

  # Double hashes the transaction outputs
  defp hash_outputs(outputs, vin, sighash_type)
       when sighash_single?(sighash_type) and
              vin < length(outputs) do
    outputs
    |> Enum.at(vin)
    |> TxOut.to_binary()
    |> Hash.sha256_sha256()
  end

  defp hash_outputs(outputs, _vin, sighash_type)
       when not sighash_none?(sighash_type) do
    outputs
    |> Enum.reduce(<<>>, &(&2 <> TxOut.to_binary(&1)))
    |> Hash.sha256_sha256()
  end

  defp hash_outputs(_outputs, _vin, _sighash_type),
    do: :binary.copy(<<0>>, 32)

  # Replaces the transaction input scripts with the subscript
  defp update_tx_inputs(inputs, vin, subscript, sighash_type)
       when sighash_anyone_can_pay?(sighash_type) do
    txin =
      Enum.at(inputs, vin)
      |> Map.put(:script, subscript)

    [txin]
  end

  defp update_tx_inputs(inputs, vin, subscript, sighash_type) do
    inputs
    |> Enum.with_index()
    |> Enum.map(fn
      {txin, ^vin} ->
        Map.put(txin, :script, subscript)

      {txin, _i} ->
        if sighash_none?(sighash_type) || sighash_single?(sighash_type),
          do: Map.merge(txin, %{script: %Script{}, sequence: 0}),
          else: Map.put(txin, :script, %Script{})
    end)
  end

  # Prepares the transaction outputs for the legacy preimage algorithm
  defp update_tx_outputs(_outputs, _vin, sighash_type)
       when sighash_none?(sighash_type),
       do: []

  defp update_tx_outputs(outputs, vin, sighash_type)
       when sighash_single?(sighash_type) and
              length(outputs) <= vin,
       do: raise(ArgumentError, "input out of txout range")

  defp update_tx_outputs(outputs, vin, sighash_type)
       when sighash_single?(sighash_type) do
    outputs
    |> Enum.with_index()
    |> Enum.map(fn
      {_txout, i} when i < vin ->
        %TxOut{satoshis: -1, script: %Script{}}

      {txout, _i} ->
        txout
    end)
    |> Enum.slice(0..vin)
  end

  defp update_tx_outputs(outputs, _vin, _sighash_type), do: outputs
end
