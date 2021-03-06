# coding: utf-8
require 'term/ansicolor'
require 'i18n/tasks/task_helpers'

module I18n
  module Tasks
    class BaseTask
      include TaskHelpers

      # locale data hash, with locale name as root
      # @return [Hash{String => String,Hash}] locale data in nested hash format
      def locale_data(locale)
        locale                        = locale.to_s
        (@locale_data ||= {})[locale] ||= data_source.get(locale)
      end

      def data_source
        return @source if @source
        conf    = config[:data] || {}
        @source = if conf[:class]
                    conf[:class].constantize.new(conf.except(:class))
                  else
                    I18n::Tasks::Data::Yaml.new(
                        paths: Array(conf[:paths].presence || ['config/locales/%{locale}.yml'])
                    )
                  end
      end

      # main locale file path (for writing to)
      # @return [String]
      def locale_file_path(locale)
        "config/locales/#{locale}.yml"
      end

      # find all keys in the source (relative keys are returned in absolutized)
      # @return [Array<String>]
      def find_source_keys
        @source_keys ||= begin
          if (grep_out = run_grep)
            grep_out.split("\n").map { |r|
              key = r.match(/['"](.*?)['"]/)[1]
              if key.start_with? '.'
                absolutize_key key, r.split(':')[0]
              else
                key
              end
            }.uniq.reject { |k| k !~ /^[\w.\#{}]+$/ }
          else
            []
          end
        end
      end

      # whether the key is used in the source
      def used_key?(key)
        @used_keys ||= find_source_keys.to_set
        @used_keys.include?(key)
      end

      # whether to ignore the key. ignore_type one of :missing, :eq_base, :blank, :unused.
      # will apply global ignore rules as well
      def ignore_key?(key, ignore_type, locale = nil)
        key =~ ignore_pattern(ignore_type, locale)
      end

      # dynamically generated keys in the source, e.g t("category.#{category_key}")
      def pattern_key?(key)
        @pattern_keys_re ||= compile_start_with_re(pattern_key_prefixes)
        key =~ @pattern_keys_re
      end

      # keys in the source that end with a ., e.g. t("category.#{cat.i18n_key}") or t("category." + category.key)
      def pattern_key_prefixes
        @pattern_keys_prefixes ||=
            find_source_keys.select { |k| k =~ /\#{.*?}/ || k.ends_with?('.') }.map { |k| k.split(/\.?#/)[0].presence }.compact
      end

      # whether the value for key exists in locale (defaults: base_locale)
      def key_has_value?(key, locale = base_locale)
        t(locale_data(locale)[locale], key).present?
      end

      # traverse hash, yielding with full key and value
      # @param hash [Hash{String => String,Hash}] translation data to traverse
      # @yield [full_key, value] yields full key and value for every translation in #hash
      # @return [nil]
      def traverse(path = '', hash)
        q = [[path, hash]]
        until q.empty?
          path, value = q.pop
          if value.is_a?(Hash)
            value.each { |k, v| q << ["#{path}.#{k}", v] }
          else
            yield path[1..-1], value
          end
        end
      end

      # translation of the key found in the passed hash or nil
      # @return [String,nil]
      def t(hash, key)
        key.split('.').inject(hash) { |r, seg| r[seg] if r }
      end

      # @param key [String] relative i18n key (starts with a .)
      # @param path [String] path to the file containing the key
      # @return [String] absolute version of the key
      def absolutize_key(key, path)
        # normalized path
        path   = Pathname.new(File.expand_path path).relative_path_from(Pathname.new(Dir.pwd)).to_s
        # key prefix based on path
        prefix = path.gsub(%r(app/views/|(\.[^/]+)*$), '').tr('/', '.').gsub(%r(\._), '.')
        "#{prefix}#{key}"
      end

      PLURAL_KEY_RE = /\.(?:zero|one|two|few|many|other)$/

      # @param key [String] i18n key
      # @param data [Hash{String => String,Hash}] locale data
      # @return the base form if the key is a specific plural form (e.g. apple for apple.many), and the key as passed otherwise
      def depluralize_key(key, data)
        return key if key !~ PLURAL_KEY_RE || t(data, key).is_a?(Hash)
        parent_key      = key.split('.')[0..-2] * '.'
        plural_versions = t(data, parent_key)
        if plural_versions.is_a?(Hash) && plural_versions.all? { |k, v| ".#{k}" =~ PLURAL_KEY_RE && !v.is_a?(Hash) }
          parent_key
        else
          key
        end
      end


      # @return [String] default i18n locale
      def base_locale
        I18n.default_locale.to_s
      end

      # @return [Hash{String => String,Hash}] default i18n locale data
      def base_locale_data
        locale_data(base_locale)[base_locale]
      end

      # Run grep searching for source keys and return grep output
      # @return [String] output of the grep command
      def run_grep
        args = ['grep', '-HoRI']
        [:include, :exclude].each do |opt|
          next unless (val = grep_config[opt]).present?
          args += Array(val).map { |v| "--#{opt}=#{v}" }
        end
        args += [%q{\\bt(\\?\\s*['"]\\([^'"]*\\)['"]}, *grep_config[:paths]]
        args.compact!
        run_command *args
      end

    end
  end
end
