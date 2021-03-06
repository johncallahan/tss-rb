module TSS
  # Warning, you probably don't want to use this directly. Instead
  # see the TSS module.
  #
  # TSS::Combiner has responsibility for combining an Array of String shares back
  # into the original secret the shares were split from. It is also responsible
  # for doing extensive validation of user provided shares and ensuring
  # that any recovered secret matches the hash of the original secret.
  class Combiner
    include Contracts::Core
    include Util

    C = Contracts

    attr_reader :shares, :select_by, :padding

    Contract ({ :shares => C::ArrayOfShares, :select_by => C::Maybe[C::SelectByArg], :padding => C::Maybe[C::Bool] }) => C::Any
    def initialize(opts = {})
      # clone the incoming shares so the object passed to this
      # function doesn't get modified.
      @shares = opts.fetch(:shares).clone
      @select_by = opts.fetch(:select_by, 'FIRST')
      @padding = opts.fetch(:padding, true)
    end

    # Warning, you probably don't want to use this directly. Instead
    # see the TSS module.
    #
    # To reconstruct a secret from a set of shares, the following
    # procedure, or any equivalent method, is used:
    #
    #   If the number of shares provided as input to the secret
    #   reconstruction operation is greater than the threshold M, then M
    #   of those shares are selected for use in the operation.  The method
    #   used to select the shares can be arbitrary.
    #
    #   If the shares are not equal length, then the input is
    #   inconsistent.  An error should be reported, and processing must
    #   halt.
    #
    #   The output string is initialized to the empty (zero-length) octet
    #   string.
    #
    #   The octet array U is formed by setting U[i] equal to the first
    #   octet of the ith share.  (Note that the ordering of the shares is
    #   arbitrary, but must be consistent throughout this algorithm.)
    #
    #   The initial octet is stripped from each share.
    #
    #   If any two elements of the array U have the same value, then an
    #   error condition has occurred; this fact should be reported, then
    #   the procedure must halt.
    #
    #   For each octet of the shares, the following steps are performed.
    #   An array V of M octets is created, in which the array element V[i]
    #   contains the octet from the ith share.  The value of I(U, V) is
    #   computed, then appended to the output string.
    #
    #   The output string is returned (along with some metadata).
    #
    #
    # @return an Hash of combined secret attributes
    # @raise [ParamContractError, TSS::ArgumentError] if the options Types or Values are invalid
    # rubocop:disable CyclomaticComplexity
    Contract C::None => ({ :hash => C::Maybe[String], :hash_alg => C::HashAlgArg, :identifier => C::IdentifierArg, :process_time => C::Num, :secret => C::SecretArg, :threshold => C::ThresholdArg})
    def combine
      # unwrap 'human' shares into binary shares
      if all_shares_appear_human?(shares)
        @shares = convert_shares_human_to_binary(shares)
      end

      validate_all_shares(shares)
      start_processing_time = Time.now

      h          = Util.extract_share_header(shares.sample)
      threshold  = h[:threshold]
      identifier = h[:identifier]
      hash_id    = h[:hash_id]

      # Select a subset of the shares provided using the chosen selection
      # method. If there are exactly the right amount of shares this is a no-op.
      if select_by == 'FIRST'
        @shares = shares.shift(threshold)
      elsif select_by == 'SAMPLE'
        @shares = shares.sample(threshold)
      end

      # slice out the data after the header bytes in each share
      # and unpack the byte string into an Array of Byte Arrays
      shares_bytes = shares.map do |s|
        bytestring = s.byteslice(Splitter::SHARE_HEADER_STRUCT.size..s.bytesize)
        bytestring.unpack('C*') unless bytestring.nil?
      end.compact

      shares_bytes_have_valid_indexes!(shares_bytes)

      if select_by == 'COMBINATIONS'
        share_combinations_mode_allowed!(hash_id)
        share_combinations_out_of_bounds!(shares, threshold)

        # Build an Array of all possible `threshold` size combinations.
        share_combos = shares_bytes.combination(threshold).to_a

        # Try each combination until one works.
        secret = nil
        while secret.nil? && share_combos.present?
          # Check a combination and shift it off the Array
          result = extract_secret_from_shares!(hash_id, share_combos.shift)
          next if result.nil?
          secret = result
        end
      else
        secret = extract_secret_from_shares!(hash_id, shares_bytes)
      end

      # Return a Hash with the secret and metadata
      {
        hash: secret[:hash],
        hash_alg: secret[:hash_alg],
        identifier: identifier,
        process_time: ((Time.now - start_processing_time)*1000).round(2),
        secret: Util.bytes_to_utf8(secret[:secret]),
        threshold: threshold
      }
    end
    # rubocop:enable CyclomaticComplexity

    private

    # Given a hash ID and an Array of Arrays of Share Bytes, extract a secret
    # and validate it against any one-way hash that was embedded in the shares
    # along with the secret.
    #
    # @param hash_id the ID of the one-way hash function to test with
    # @param shares_bytes the shares as Byte Arrays to be evaluated
    # @return returns the secret as an Array of Bytes if it was recovered from the shares and validated
    # @raise [TSS::NoSecretError] if the secret was not able to be recovered (with no hash)
    # @raise [TSS::InvalidSecretHashError] if the secret was able to be recovered but the hash test failed
    Contract C::Int, C::ArrayOf[C::ArrayOf[C::Num]] => ({ :secret => C::ArrayOf[C::Num], :hash => C::Maybe[String], :hash_alg => C::HashAlgArg })
    def extract_secret_from_shares!(hash_id, shares_bytes)
      secret = []

      # build up an Array of index values from each share
      # u[i] equal to the first octet of the ith share
      u = shares_bytes.map { |s| s[0] }

      # loop through each byte in all the shares
      # start at Array index 1 in each share's Byte Array to skip the index
      (1..(shares_bytes.first.length - 1)).each do |i|
        v = shares_bytes.map { |share| share[i] }
        secret << Util.lagrange_interpolation(u, v)
      end

      hash_alg = Hasher.key_from_code(hash_id)

      # Run the hash digest checks if the shares were created with a digest
      if Hasher.codes_without_none.include?(hash_id)
        # RTSS : pop off the hash digest bytes from the tail of the secret. This
        # leaves `secret` with only the secret bytes remaining.
        orig_hash_bytes = secret.pop(Hasher.bytesize(hash_alg))
        orig_hash_hex = Util.bytes_to_hex(orig_hash_bytes)

        # Remove PKCS#7 padding from the secret now that the hash
        # has been extracted from the data
        secret = Util.unpad(secret) if padding

        # RTSS : verify that the recombined secret computes the same hash
        # digest now as when it was originally created.
        new_hash_bytes = Hasher.byte_array(hash_alg, Util.bytes_to_utf8(secret))
        new_hash_hex = Util.bytes_to_hex(new_hash_bytes)

        unless Util.secure_compare(orig_hash_hex, new_hash_hex)
          raise TSS::InvalidSecretHashError, 'invalid shares, hash of secret does not equal embedded hash'
        end
      else
        secret = Util.unpad(secret) if padding
      end

      if secret.present?
        return { secret: secret, hash: orig_hash_hex, hash_alg: hash_alg }
      else
        raise TSS::NoSecretError, 'invalid shares, unable to recombine into a verifiable secret'
      end
    end

    # Do all of the shares match the pattern expected of human style shares?
    #
    # @param shares the shares to be evaluated
    # @return returns true if all shares match the patterns, false if not
    # @raise [ParamContractError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def all_shares_appear_human?(shares)
      shares.all? do |s|
        # test for starting with 'tss' since regex match against
        # binary data sometimes throws exceptions.
        s.start_with?('tss~') && s.match(Util::HUMAN_SHARE_RE)
      end
    end

    # Convert an Array of human style shares to binary style
    #
    # @param shares the shares to be converted
    # @return returns an Array of String shares in binary octet String format
    # @raise [ParamContractError, TSS::ArgumentError] if shares appear invalid
    Contract C::ArrayOf[String] => C::ArrayOf[String]
    def convert_shares_human_to_binary(shares)
      shares.map do |s|
        s_b64 = s.match(Util::HUMAN_SHARE_RE)
        if s_b64.present? && s_b64.to_a[1].present?
          begin
            # the [1] capture group contains the Base64 encoded bin share
            Base64.urlsafe_decode64(s_b64.to_a[1])
          rescue ArgumentError
            raise TSS::ArgumentError, 'invalid shares, some human format shares have invalid Base64 data'
          end
        else
          raise TSS::ArgumentError, 'invalid shares, some human format shares do not match expected pattern'
        end
      end
    end

    # Do all shares have a common Byte size? They are invalid if not.
    #
    # @param shares the shares to be evaluated
    # @return returns true if all shares have the same Byte size
    # @raise [ParamContractError, TSS::ArgumentError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def shares_have_same_bytesize!(shares)
      shares.each do |s|
        unless s.bytesize == shares.first.bytesize
          raise TSS::ArgumentError, 'invalid shares, different byte lengths'
        end
      end
      return true
    end

    # Do all shares have a valid header and match each other? They are invalid if not.
    #
    # @param shares the shares to be evaluated
    # @return returns true if all shares have the same header
    # @raise [ParamContractError, TSS::ArgumentError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def shares_have_valid_headers!(shares)
      fh = Util.extract_share_header(shares.first)

      unless Contract.valid?(fh, ({ :identifier => String, :hash_id => C::Int, :threshold => C::Int, :share_len => C::Int }))
        raise TSS::ArgumentError, 'invalid shares, headers have invalid structure'
      end

      shares.each do |s|
        unless Util.extract_share_header(s) == fh
          raise TSS::ArgumentError, 'invalid shares, headers do not match'
        end
      end

      return true
    end

    # Do all shares have a the expected length? They are invalid if not.
    #
    # @param shares the shares to be evaluated
    # @return returns true if all shares have the same header
    # @raise [ParamContractError, TSS::ArgumentError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def shares_have_expected_length!(shares)
      shares.each do |s|
        unless s.bytesize > Splitter::SHARE_HEADER_STRUCT.size + 1
          raise TSS::ArgumentError, 'invalid shares, too short'
        end
      end
      return true
    end

    # Were enough shares provided to meet the threshold? They are invalid if not.
    #
    # @param shares the shares to be evaluated
    # @return returns true if there are enough shares
    # @raise [ParamContractError, TSS::ArgumentError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def shares_meet_threshold_min!(shares)
      fh = Util.extract_share_header(shares.first)
      unless shares.size >= fh[:threshold]
        raise TSS::ArgumentError, 'invalid shares, fewer than threshold'
      else
        return true
      end
    end

    # Were enough shares provided to meet the threshold? They are invalid if not.
    #
    # @param shares the shares to be evaluated
    # @return returns true if all tests pass
    # @raise [ParamContractError] if shares appear invalid
    Contract C::ArrayOf[String] => C::Bool
    def validate_all_shares(shares)
      if shares_have_valid_headers!(shares) &&
         shares_have_same_bytesize!(shares) &&
         shares_have_expected_length!(shares) &&
         shares_meet_threshold_min!(shares)
        return true
      else
        return false
      end
    end

    # Do all the shares have a valid first-byte index? They are invalid if not.
    #
    # @param shares_bytes the shares as Byte Arrays to be evaluated
    # @return returns true if there are enough shares
    # @raise [ParamContractError, TSS::ArgumentError] if shares bytes appear invalid
    Contract C::ArrayOf[C::ArrayOf[C::Num]] => C::Bool
    def shares_bytes_have_valid_indexes!(shares_bytes)
      u = shares_bytes.map do |s|
        raise TSS::ArgumentError, 'invalid shares, no index' if s[0].blank?
        raise TSS::ArgumentError, 'invalid shares, zero index' if s[0] == 0
        s[0]
      end

      unless u.uniq.size == shares_bytes.size
        raise TSS::ArgumentError, 'invalid shares, duplicate indexes'
      else
        return true
      end
    end

    # Is it valid to use combinations mode? Only when there is an embedded non-zero
    # hash_id Integer to test the results against. Invalid if not.
    #
    # @param hash_id the shares as Byte Arrays to be evaluated
    # @return returns true if OK to use combinations mode
    # @raise [ParamContractError, TSS::ArgumentError] if hash_id represents a non hashing type
    Contract C::Int => C::Bool
    def share_combinations_mode_allowed!(hash_id)
      unless Hasher.codes_without_none.include?(hash_id)
        raise TSS::ArgumentError, 'invalid options, combinations mode can only be used with hashed shares.'
      else
        return true
      end
    end

    # Calculate the number of possible combinations when combinations mode is
    # selected. Raise an exception if the possible combinations are too large.
    #
    # If this is not tested, the number of combinations can quickly grow into
    # numbers that cannot be calculated before the end of the universe.
    # e.g. 255 total shares, with threshold of 128, results in # combinations of:
    # 2884329411724603169044874178931143443870105850987581016304218283632259375395
    #
    # @param shares the shares to be evaluated
    # @param threshold the threshold value set in the shares
    # @param max_combinations the max (1_000_000) number of combinations allowed
    # @return returns true if a reasonable number of combinations
    # @raise [ParamContractError, TSS::ArgumentError] if args are invalid or the number of possible combinations is unreasonably high
    Contract C::ArrayOf[String], C::Int, C::Int => C::Bool
    def share_combinations_out_of_bounds!(shares, threshold, max_combinations = 1_000_000)
      combinations = Util.calc_combinations(shares.size, threshold)
      if combinations > max_combinations
        raise TSS::ArgumentError, "invalid options, too many combinations (#{combinations})"
      else
        return true
      end
    end
  end
end
