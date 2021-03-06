defmodule ProxerEx.Client do
  @moduledoc """
    Proxer API Client
  """

  @type api_key :: binary() | :test

  @type t :: %ProxerEx.Client{
          key: binary() | :test,
          login_token: binary(),
          options: ProxerEx.Options.t()
        }
  @enforce_keys [:key]
  defstruct [
    :key,
    :login_token,
    :options
  ]

  alias ProxerEx.Helper.{KeywordHelper, MapHelper}

  @doc """
  Creates a new client with the given api key and some optional options.

  If key is `:test` the client will access the test mode of the api.

  Returns a `ProxerEx.Client` struct.


  ## Examples

      iex> ProxerEx.Client.create("XXXXXXXXXXXXXXXX")
      {:ok,
        %ProxerEx.Client{
          key: "XXXXXXXXXXXXXXXX",
          options: %ProxerEx.Options{
            device: "ProxerEx/#{ProxerEx.MixProject.project()[:version]}",
            host: "proxer.me",
            path: "/api",
            use_ssl: true
          }
        }
      }

      iex> ProxerEx.Client.create("YYYYYYYYYYYYYYY", %ProxerEx.Options{host: "localhost"})
      {:ok,
        %ProxerEx.Client{
          key: "YYYYYYYYYYYYYYY",
          options: %ProxerEx.Options{
            device: "ProxerEx/#{ProxerEx.MixProject.project()[:version]}",
            host: "localhost",
            path: "/api",
            use_ssl: true
          }
        }
      }

      iex> ProxerEx.Client.create(:test)
      {:ok,
        %ProxerEx.Client{
          key: :test,
          options: %ProxerEx.Options{
            device: "ProxerEx/#{ProxerEx.MixProject.project()[:version]}",
            host: "proxer.me",
            path: "/api",
            use_ssl: true
          }
        }
      }

  """
  @spec create(key :: api_key(), options :: ProxerEx.Options.t()) ::
          {:ok, ProxerEx.Client.t()} | {:error, :invalid_parameters} | {:error, any()}
  def create(key, options \\ %ProxerEx.Options{})

  def create(:test, %ProxerEx.Options{} = options) do
    {:ok,
     %ProxerEx.Client{
       key: :test,
       options: options
     }}
  end

  def create(key, %ProxerEx.Options{} = options) when is_binary(key) do
    {:ok,
     %ProxerEx.Client{
       key: key,
       options: options
     }}
  end

  def create(_key, _options) do
    {:error, :invalid_parameters}
  end

  @doc """
  Makes a request to the api through the given client.

  Returns `{:ok, %ProxerEx.Response{...}}` if the request was successful or `{:error, error}` else.


  ## Examples

      iex> {:ok, client} = ProxerEx.Client.create("ZZZZZZZZZZZZZ")
      iex> {:ok, request} = ProxerEx.Api.List.characters()
      iex> ProxerEx.Client.make_request(request, client)
      {:ok, %ProxerEx.Response{...}}

  """
  @spec make_request(request :: ProxerEx.Request.t(), client :: ProxerEx.Client.t()) ::
          {:ok, ProxerEx.Response.t()}
          | {:error, :invalid_parameters}
          | {:error, Tesla.Env.t()}
          | {:error, any()}
  def make_request(
        %ProxerEx.Request{method: method, get_args: query, post_args: post_args} = request,
        %ProxerEx.Client{options: %ProxerEx.Options{} = options} = client
      ) do
    with {:ok, url} <- create_api_url(request, options),
         {:ok, header} <- create_headers(request, client),
         {:ok, %Tesla.Env{body: body, status: 200}} when is_map(body) <-
           do_request(method, url, Map.to_list(query), post_args, header) do
      body =
        body
        |> MapHelper.to_atom_map()
        |> Map.update(:error, 1, &(&1 != 0))

      {:ok, struct(ProxerEx.Response, body)}
    else
      {:ok, %Tesla.Env{} = response} ->
        {:error, response}

      {:error, :invalid_parameters} ->
        # Do not pass invalid_parameters as it may cause confusion for the user
        {:error, :unkown}

      {:error, error} ->
        {:error, error}

      error ->
        {:error, error}
    end
  end

  def make_request(_request, _client) do
    {:error, :invalid_parameters}
  end

  @spec create_api_url(request :: ProxerEx.Request.t(), options :: ProxerEx.Options.t()) ::
          {:ok, binary()} | {:error, :invalid_parameters} | {:error, any()}
  defp create_api_url(
         %ProxerEx.Request{api_class: api_class, api_func: api_func},
         %ProxerEx.Options{host: host, path: path, port: port, use_ssl: use_ssl}
       ) do
    uri =
      %URI{
        scheme: "http#{if use_ssl, do: "s"}",
        host: host,
        port: port,
        path: "#{path}/v1/#{api_class}/#{api_func}"
      }
      |> URI.to_string()

    {:ok, uri}
  end

  defp create_api_url(_request, _options) do
    {:error, :invalid_parameters}
  end

  @spec create_headers(request :: ProxerEx.Request.t(), client :: ProxerEx.Client.t()) ::
          {:ok, keyword(binary())} | {:error, :invalid_parameters} | {:error, any()}
  defp create_headers(
         %ProxerEx.Request{extra_header: headers, authorization: authorization},
         %ProxerEx.Client{
           key: api_key,
           login_token: login_token,
           options: %ProxerEx.Options{device: device}
         }
       )
       when is_list(headers) do
    # Add device header to identify the used client
    headers = headers |> Keyword.put_new(:"User-Agent", device)

    headers =
      if api_key == :test do
        # Add the correct header if we are in api test mode
        headers |> Keyword.put_new(:"proxer-api-testmode", "1")
      else
        # Only add the api key to the request if we are not in api test mode
        headers |> Keyword.put_new(:"proxer-api-key", api_key)
      end

    # Add the authorization header if one is needed for the request and one is given
    headers =
      if authorization and login_token != nil do
        headers |> Keyword.put_new(:"proxer-api-token", login_token)
      else
        headers
      end

    {:ok, headers}
  end

  defp create_headers(_request, _client) do
    {:error, :invalid_parameters}
  end

  @spec do_request(
          method :: ProxerEx.Request.http_method(),
          url :: binary(),
          query :: keyword(binary()),
          post_args :: keyword(binary()),
          headers :: keyword(binary())
        ) :: {:ok, Tesla.Env.t()} | {:error, :invalid_parameters} | {:error, any()}
  defp do_request(:get, url, query, _post_args, headers)
       when is_binary(url) and is_list(query) and is_list(headers) do
    headers = KeywordHelper.to_string_list(headers)
    ProxerEx.TeslaClient.get(url, headers: headers, query: query)
  end

  defp do_request(:post, url, query, post_args, headers)
       when is_binary(url) and is_list(query) and is_list(post_args) and is_list(headers) do
    headers = KeywordHelper.to_string_list(headers)
    ProxerEx.TeslaClient.post(url, post_args, headers: headers, query: query)
  end

  defp do_request(_method, _url, _query, _post_args, _headers) do
    {:error, :invalid_parameters}
  end
end
