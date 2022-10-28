defprotocol BSV.Serializable do
  @moduledoc """
  A protocol module specifying an API for parsing and serializing Binary data
  into Bitcoin objects.
  """

  @doc """
  Parses the binary value into the specified type.

  Returns a tuple containing the parsed term and the remaining binary data.
  """
  @spec parse(t(), binary()) :: {:ok, t(), binary()} | {:error, term()}
  def parse(type, data)

  @doc """
  Parses the struct into a binary value.
  """
  @spec serialize(t()) :: binary()
  def serialize(type)
end
