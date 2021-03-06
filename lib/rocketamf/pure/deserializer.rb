require 'rocketamf/pure/io_helpers'

module RocketAMF
  module Pure
    # Pure ruby deserializer
    #--
    # AMF0 deserializer, it switches over to AMF3 when it sees the switch flag
    class Deserializer
      attr_accessor :source

      def initialize
        @ref_cache = []
      end

      def deserialize(source=nil, type=nil)
        if source
          @source = StringIO === source ? source : StringIO.new(source)
        end

        type = read_int8 @source unless type
        case type
        when AMF0_NUMBER_MARKER
          read_number
        when AMF0_BOOLEAN_MARKER
          read_boolean
        when AMF0_STRING_MARKER
          read_string
        when AMF0_OBJECT_MARKER
          read_object
        when AMF0_NULL_MARKER
          nil
        when AMF0_UNDEFINED_MARKER
          nil
        when AMF0_REFERENCE_MARKER
          read_reference
        when AMF0_HASH_MARKER
          read_hash
        when AMF0_STRICT_ARRAY_MARKER
          read_array
        when AMF0_DATE_MARKER
          read_date
        when AMF0_LONG_STRING_MARKER
          read_string true
        when AMF0_UNSUPPORTED_MARKER
          nil
        when AMF0_XML_MARKER
          read_string true
        when AMF0_TYPED_OBJECT_MARKER
          read_typed_object
        when AMF0_AMF3_MARKER
          AMF3Deserializer.new.deserialize(@source)
        else
          raise AMFError, "Invalid type: #{type}"
        end
      end

      private
      include RocketAMF::Pure::ReadIOHelpers

      def read_number
        res = read_double @source
        res.is_a?(Float)&&res.nan? ? nil : res # check for NaN and convert them to nil
      end

      def read_boolean
        read_int8(@source) != 0
      end

      def read_string long=false
        len = long ? read_word32_network(@source) : read_word16_network(@source)
        str = @source.read(len)
        str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
        str
      end

      def read_object add_to_ref_cache=true, translate_case=false
        obj = {}
        @ref_cache << obj if add_to_ref_cache
        while true
          key = read_string
          type = read_int8 @source
          break if type == AMF0_OBJECT_END_MARKER
          key.gsub!(/([A-Z])/) { "_" + $1.downcase } if translate_case

          obj[key.to_sym] = deserialize(nil, type)
        end
        obj
      end

      def read_reference
        index = read_word16_network(@source)
        @ref_cache[index]
      end

      def read_hash
        class_name = RocketAMF::ClassMapper.get_as_class_name 'Hash'
        translate_case = RocketAMF::ClassMapper.get_as_option(class_name, 'translate_case')

        len = read_word32_network(@source) # Read and ignore length
        obj = {}
        @ref_cache << obj
        while true
          key = read_string
          type = read_int8 @source
          break if type == AMF0_OBJECT_END_MARKER

          key.gsub!(/([A-Z])/) { "_" + $1.downcase } if translate_case

          obj[key] = deserialize(nil, type)
        end
        obj
      end

      def read_array
        len = read_word32_network(@source)
        array = []
        @ref_cache << array

        0.upto(len - 1) do
          array << deserialize
        end
        array
      end

      def read_date
        seconds = read_double(@source).to_f/1000
        time = Time.at(seconds)
        tz = read_word16_network(@source) # Unused
        time
      end

      def read_typed_object
        # Create object to add to ref cache
        class_name = read_string
        translate_case = RocketAMF::ClassMapper.get_as_option(class_name, 'translate_case')

        obj = RocketAMF::ClassMapper.get_ruby_obj class_name
        @ref_cache << obj


        # Read object props
        props = read_object false, translate_case

        # Populate object
        RocketAMF::ClassMapper.populate_ruby_obj obj, props
        return obj
      end
    end

    # AMF3 implementation of deserializer, loaded automatically by the AMF0
    # deserializer when needed
    class AMF3Deserializer
      attr_accessor :source

      def initialize
        @string_cache = []
        @object_cache = []
        @trait_cache = []
      end

      def deserialize(source=nil, opts=nil)
        if source
          @source = StringIO === source ? source : StringIO.new(source)
        end

        type = read_int8 @source
        case type
        when AMF3_UNDEFINED_MARKER
          nil
        when AMF3_NULL_MARKER
          nil
        when AMF3_FALSE_MARKER
          false
        when AMF3_TRUE_MARKER
          true
        when AMF3_INTEGER_MARKER
          read_integer
        when AMF3_DOUBLE_MARKER
          read_number
        when AMF3_STRING_MARKER
          read_string
        when AMF3_XML_DOC_MARKER, AMF3_XML_MARKER
          read_xml
        when AMF3_DATE_MARKER
          read_date
        when AMF3_ARRAY_MARKER
          read_array
        when AMF3_OBJECT_MARKER
          read_object
        when AMF3_BYTE_ARRAY_MARKER
          read_amf3_byte_array
        when AMF3_DICT_MARKER
          read_dict
        else
          raise AMFError, "Invalid type: #{type}"
        end
      end

      private
      include RocketAMF::Pure::ReadIOHelpers

      def read_integer
        n = 0
        b = read_word8(@source) || 0
        result = 0

        while ((b & 0x80) != 0 && n < 3)
          result = result << 7
          result = result | (b & 0x7f)
          b = read_word8(@source) || 0
          n = n + 1
        end

        if (n < 3)
          result = result << 7
          result = result | b
        else
          #Use all 8 bits from the 4th byte
          result = result << 8
          result = result | b

          #Check if the integer should be negative
          if (result > MAX_INTEGER)
            result -= (1 << 29)
          end
        end
        result
      end

      def read_number
        res = read_double @source
        res.is_a?(Float)&&res.nan? ? nil : res # check for NaN and convert them to nil
      end

      def read_string
        type = read_integer
        isReference = (type & 0x01) == 0

        if isReference
          reference = type >> 1
          return @string_cache[reference]
        else
          length = type >> 1
          str = ""
          if length > 0
            str = @source.read(length)
            str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
            @string_cache << str
          end
          return str
        end
      end

      def read_xml
        type = read_integer
        isReference = (type & 0x01) == 0

        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          str = ""
          if length > 0
            str = @source.read(length)
            str.force_encoding("UTF-8") if str.respond_to?(:force_encoding)
            @object_cache << str
          end
          return str
        end
      end

      def read_amf3_byte_array
        type = read_integer
        isReference = (type & 0x01) == 0

        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          obj = StringIO.new @source.read(length)
          @object_cache << obj
          obj
        end
      end

      def read_array
        type = read_integer
        isReference = (type & 0x01) == 0

        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          length = type >> 1
          propertyName = read_string
          if propertyName != ""
            array = {}
            @object_cache << array
            begin
              while(propertyName.length)
                value = deserialize
                array[propertyName] = value
                propertyName = read_string
              end
            rescue Exception => e #end of object exception, because propertyName.length will be non existent
            end
            0.upto(length - 1) do |i|
              array["" + i.to_s] = deserialize
            end
          else
            array = []
            @object_cache << array
            0.upto(length - 1) do
              array << deserialize
            end
          end
          array
        end
      end

      def read_object
        type = read_integer
        isReference = (type & 0x01) == 0

        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          class_type = type >> 1
          class_is_reference = (class_type & 0x01) == 0

          if class_is_reference
            reference = class_type >> 1
            traits = @trait_cache[reference]
          else
            externalizable = (class_type & 0x02) != 0
            dynamic = (class_type & 0x04) != 0
            attribute_count = class_type >> 3
            class_name = read_string

            class_attributes = []
            attribute_count.times{class_attributes << read_string} # Read class members

            traits = {
                      :class_name => class_name,
                      :members => class_attributes,
                      :externalizable => externalizable,
                      :dynamic => dynamic
                     }
            @trait_cache << traits
          end

          # Optimization for deserializing ArrayCollection
          if traits[:class_name] == "flex.messaging.io.ArrayCollection"
            arr = deserialize # Adds ArrayCollection array to object cache
            @object_cache << arr # Add again for ArrayCollection source array
            return arr
          end

          obj = RocketAMF::ClassMapper.get_ruby_obj traits[:class_name]
          @object_cache << obj

          if traits[:externalizable]
            obj.read_external self
          else
            translate_case = RocketAMF::ClassMapper.get_as_option(traits[:class_name], 'translate_case')

            props = {}
            traits[:members].each do |key|
              value = deserialize
              key.gsub!(/([A-Z])/) { "_" + $1.downcase } if translate_case
              props[key.to_sym] = value
            end

            dynamic_props = nil
            if traits[:dynamic]
              dynamic_props = {}
              while (key = read_string) && key.length != 0  do # read next key
                value = deserialize
                key.gsub!(/([A-Z])/) { "_" + $1.downcase } if translate_case
                dynamic_props[key.to_sym] = value
              end
            end

            RocketAMF::ClassMapper.populate_ruby_obj obj, props, dynamic_props
          end
          obj
        end
      end

      def read_date
        type = read_integer
        isReference = (type & 0x01) == 0
        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          seconds = read_double(@source).to_f/1000
          time = Time.at(seconds)
          @object_cache << time
          time
        end
      end

      def read_dict
        type = read_integer
        # Currently duplicate dictionaries send false, but I'll leave this in here just in case
        isReference = (type & 0x01) == 0
        if isReference
          reference = type >> 1
          return @object_cache[reference]
        else
          dict = {}
          @object_cache << dict
          length = type >> 1
          skip = read_integer # TODO: Handle when specs are updated
          0.upto(length - 1) do |i|
            dict[deserialize] = deserialize
          end
          dict
        end
      end
    end
  end
end
