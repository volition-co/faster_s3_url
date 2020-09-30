# frozen_string_literal: true

module FasterS3Url
  # Signing algorithm based on Amazon docs at https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html ,
  # as well as some interactive code reading of Aws::Sigv4::Signer
  # https://github.com/aws/aws-sdk-ruby/blob/6114bc9692039ac75c8292c66472dacd14fa6f9a/gems/aws-sigv4/lib/aws-sigv4/signer.rb
  # as used by Aws::S3::Presigner https://github.com/aws/aws-sdk-ruby/blob/6114bc9692039ac75c8292c66472dacd14fa6f9a/gems/aws-sdk-s3/lib/aws-sdk-s3/presigner.rb
  class Builder
    FIFTEEN_MINUTES = 60 * 15
    ONE_WEEK = 60 * 60 * 24 * 7

    SIGNED_HEADERS = "host".freeze
    METHOD = "GET".freeze
    ALGORITHM = "AWS4-HMAC-SHA256".freeze
    SERVICE = "s3".freeze

    DEFAULT_EXPIRES_IN = FIFTEEN_MINUTES # 15 minutes, seems to be AWS SDK default

    attr_reader :bucket_name, :region, :host, :access_key_id

    # @option params [String] :bucket_name required
    #
    # @option params [String] :region eg "us-east-1", required
    #
    # @option params[String] :host optional, host to use in generated URLs. If empty, will construct default AWS S3 host for bucket name and region.
    #
    # @option params [String] :access_key_id required at present, change to allow look up from environment using standard aws sdk routines?
    #
    # @option params [String] :secret_access_key required at present, change to allow look up from environment using standard aws sdk routines?
    #
    # @option params [boolean] :default_public (true) default value of `public` when instance method #url is called.
    def initialize(bucket_name:, region:, access_key_id:, secret_access_key:, host:nil, default_public: true)
      @bucket_name = bucket_name
      @region = region
      @host = host || default_host(bucket_name)
      @default_public = default_public
      @access_key_id = access_key_id
      @secret_access_key = secret_access_key
    end

    def public_url(key)
      "https://#{self.host}/#{uri_escape_key(key)}"
    end

    # Generates a presigned GET URL for a specified S3 object key.
    #
    # @param [String] key The S3 key to create a URL pointing to.
    #
    # @option params [Time] :time (Time.now) The starting time for when the
    #   presigned url becomes active.
    #
    # @option params [String] :response_cache_control
    #   Adds a `response-cache-control` query param to set the `Cache-Control` header of the subsequent response from S3.
    #
    # @option params [String] :response_content_disposition
    #   Adds a `response-content-disposition` query param to set the `Content-Disposition` header of the subsequent response from S3
    #
    # @option params [String] :response_content_encoding
    #   Adds a `response-content-encoding` query param to set `Content-Encoding` header of the subsequent response from S3
    #
    # @option params [String] :response_content_language
    #   Adds a `response-content-language` query param to sets the `Content-Language` header of the subsequent response from S3
    #
    # @option params [String] :response_content_type
    #   Adds a `response-content-type` query param to sets the `Content-Type` header of the subsequent response from S3
    #
    # @option params [String] :response_expires
    #   Adds a `response-expires` query param to sets the `Expires` header of of the subsequent response from S3
    #
    # @option params [String] :version_id
    #   Adds a `versionId` query param to reference a specific version of the object from S3.
    def presigned_url(key, time: nil, expires_in: DEFAULT_EXPIRES_IN,
                        response_cache_control: nil,
                        response_content_disposition: nil,
                        response_content_encoding: nil,
                        response_content_language: nil,
                        response_content_type: nil,
                        response_expires: nil,
                        version_id: nil)
      validate_expires_in(expires_in)

      canonical_uri = "/" + uri_escape_key(key)

      now = time ? time.dup.utc : Time.now.utc # Uh Time#utc is mutating, not nice to do to an argument!
      amz_date  = now.strftime("%Y%m%dT%H%M%SZ")
      datestamp = now.strftime("%Y%m%d")

      credential_scope = datestamp + '/' + region + '/' + SERVICE + '/' + 'aws4_request'

      canonical_query_string_parts = [
          "X-Amz-Algorithm=#{ALGORITHM}",
          "X-Amz-Credential=" + uri_escape(@access_key_id + "/" + credential_scope),
          "X-Amz-Date=" + amz_date,
          "X-Amz-Expires=" + expires_in.to_s,
          "X-Amz-SignedHeaders=" + SIGNED_HEADERS,
        ]

      extra_params = {
        :"response-cache-control" => response_cache_control,
        :"response-content-disposition" => response_content_disposition,
        :"response-content-encoding" => response_content_encoding,
        :"response-content-language" => response_content_language,
        :"response-content-type" => response_content_type,
        :"response-expires" => response_expires,
        :"versionId" => version_id
      }.compact


      if extra_params.size > 0
        # These have to be sorted, but sort is case-sensitive, and we have a fixed
        # list of headers we know might be here... turns out they are already sorted?
        extra_param_parts = extra_params.collect {|k, v| "#{k}=#{uri_escape v}" }.join("&")
        canonical_query_string_parts << extra_param_parts
      end

      canonical_query_string = canonical_query_string_parts.join("&")

      canonical_headers = "host:#{@host}\n"

      canonical_request = ["GET",
        canonical_uri,
        canonical_query_string,
        canonical_headers,
        SIGNED_HEADERS,
        'UNSIGNED-PAYLOAD'
      ].join("\n")

      string_to_sign = [
        ALGORITHM,
        amz_date,
        credential_scope,
        Digest::SHA256.hexdigest(canonical_request)
      ].join("\n")

      signing_key = aws_get_signature_key(@secret_access_key, datestamp, region, SERVICE)
      signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key, string_to_sign)

      return "https://" + self.host + canonical_uri + "?" + canonical_query_string + "&X-Amz-Signature=" + signature
    end

    # just a convenience method that can call public_url or presigned_url based on flag
    #
    #    signer.url(object_key, public: true)
    #      #=> forwards to signer.public_url(object_key)
    #
    #    signer.url(object_key, public: false, response_content_type: "image/jpeg")
    #       #=> forwards to signer.presigned_url(object_key, response_content_type: "image/jpeg")
    #
    #  Options (sucn as response_content_type) that are not applicable to #public_url
    #  are ignored in public mode.
    #
    #  The default value of `public` can be set by initializer arg `default_public`, which
    #  is itself default true.
    #
    #      builder = FasterS3Url::Builder.new(..., default_public: false)
    #      builder.url(object_key) # will call #presigned_url
    def url(key, public: @default_public, **options)
      if public
        public_url(key)
      else
        presigned_url(key, **options)
      end
    end


    private


    # Becaues CGI.escape in MRI is written in C, this really does seem
    # to be the fastest way to get the semantics we want, starting with
    # CGI.escape and doing extra gsubs. Alternative would be using something
    # else in pure C that has the semantics we want, but does not seem available.
    def uri_escape(string)
      if string.nil?
        nil
      else
        CGI.escape(string.encode('UTF-8')).gsub('+', '%20').gsub('%7E', '~')
      end
    end

    # like uri_escape but does NOT escape `/`, leaves it alone. The appropriate
    # escaping algorithm for an S3 key turning into a URL.
    #
    # Faster to un-DRY the code with uri_escape. Yes, faster to actually just gsub
    # %2F back to /
    def uri_escape_key(string)
      if string.nil?
        nil
      else
        CGI.escape(string.encode('UTF-8')).gsub('+', '%20').gsub('%7E', '~').gsub("%2F", "/")
      end
    end

    def default_host(bucket_name)
      if region == "us-east-1"
        # use legacy one without region, as S3 seems to
        "#{bucket_name}.s3.amazonaws.com".freeze
      else
        "#{bucket_name}.s3.#{region}.amazonaws.com".freeze
      end
    end

    # `def get_signature_key` `from python example at https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
    def aws_get_signature_key(key, date_stamp, region_name, service_name)
      k_date = aws_sign("AWS4" + key, date_stamp)
      k_region = aws_sign(k_date, region_name)
      k_service = aws_sign(k_region, service_name)
      aws_sign(k_service, "aws4_request")
    end

    # `def sign` from python example at https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
    def aws_sign(key, data)
      OpenSSL::HMAC.digest("SHA256", key, data)
    end

    def validate_expires_in(expires_in)
      if expires_in > ONE_WEEK
        raise ArgumentError.new("expires_in value of #{expires_in} exceeds one-week maximum.")
      elsif expires_in <= 0
        raise ArgumentError.new("expires_in value of #{expires_in} cannot be 0 or less.")
      end
    end
  end
end
