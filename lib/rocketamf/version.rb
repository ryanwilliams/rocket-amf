module RocketAMF
  # AMF version
  VERSION         = '0.0.4'
  VERSION_ARRAY   = VERSION.split(/\./).map { |x| x.to_i } # :nodoc:
  VERSION_MAJOR   = VERSION_ARRAY[0] # :nodoc:
  VERSION_MINOR   = VERSION_ARRAY[1] # :nodoc:
  VERSION_BUILD   = VERSION_ARRAY[2] # :nodoc:
  VARIANT_BINARY  = false
end