$:.unshift File.dirname(__FILE__)
require 'gchart/version'
require 'gchart/theme'
require "open-uri"
require "uri"
require "cgi"
require 'enumerator'


class Gchart

  include GchartInfo

  @@url = "http://chart.apis.google.com/chart?"  
  @@types = ['line', 'line_xy', 'scatter', 'bar', 'venn', 'pie', 'pie_3d', 'jstize', 'sparkline', 'meter', 'map']
  @@simple_chars = ('A'..'Z').to_a + ('a'..'z').to_a + ('0'..'9').to_a
  @@chars = @@simple_chars + ['-', '.']
  @@ext_pairs = @@chars.map { |char_1| @@chars.map { |char_2| char_1 + char_2 } }.flatten
  @@file_name = 'chart.png'
  
  attr_accessor :title, :type, :width, :height, :horizontal, :grouped, :legend,
                :data, :encoding, :bar_colors, :title_color,
                :title_size, :custom, :axis_with_labels, :axis_labels,
                :bar_width_and_spacing, :id, :alt, :class, :range_markers,
                :geographical_area, :map_colors, :country_codes, :axis_range
    
  # Support for Gchart.line(:title => 'my title', :size => '400x600')
  def self.method_missing(m, options={})
    # Start with theme defaults if a theme is set
    theme = options[:theme]
    options = theme ? Chart::Theme.load(theme).to_options.merge(options) : options 
    # Extract the format and optional filename, then clean the hash
    format = options[:format] || 'url'
    @@file_name = options[:filename] unless options[:filename].nil?
    options.delete(:format)
    options.delete(:filename)
    #update map_colors to be bar_colors
    options.update(:bar_colors => options[:map_colors]) if options.has_key?(:map_colors)
    # create the chart and return it in the format asked for
    if @@types.include?(m.to_s)  
      chart = new(options.merge!({:type => m}))
      chart.send(format)
    elsif m.to_s == 'version' 
      Gchart::VERSION::STRING
    else
      "#{m} is not a supported chart format, please use one of the following: #{supported_types}."
    end  
  end
  
  def initialize(options={})
      @type = :line
      @width = 300
      @height = 200
      @horizontal = false
      @grouped = false
      @encoding = 'simple'
      # Sets the alt tag when chart is exported as image tag
      @alt = 'Google Chart'
      # Sets the CSS id selector when chart is exported as image tag
      @id = false
      # Sets the CSS class selector when chart is exported as image tag
      @class = false

      # set the options value if definable
      options.each do |attribute, value|
          send("#{attribute.to_s}=", value) if self.respond_to?("#{attribute}=")
      end
  end
  
  def self.supported_types
    @@types.join(' ')
  end
  
  # Defines the Graph size using the following format:
  # width X height
  def size=(size='300x200')
    @width, @height = size.split("x").map { |dimension| dimension.to_i }
  end
  
  def size
    "#{@width}x#{@height}"
  end

  def dimensions
    # TODO: maybe others?
    [:line_xy, :scatter].include?(@type) ? 2 : 1
  end

  # Sets the orientation of a bar graph
  def orientation=(orientation='h')
    if orientation == 'h' || orientation == 'horizontal'
      self.horizontal = true
    elsif orientation == 'v' || orientation == 'vertical'
      self.horizontal = false
    end
  end
  
  # Sets the bar graph presentation (stacked or grouped)
  def stacked=(option=true)
   @grouped = option ? false : true
  end
  
  def bg=(options)
    if options.is_a?(String)
      @bg_color = options
    elsif options.is_a?(Hash)
      @bg_color = options[:color]
      @bg_type = options[:type]
      @bg_angle = options[:angle]
    end
  end
  
  def graph_bg=(options)
    if options.is_a?(String)
      @chart_color = options
    elsif options.is_a?(Hash)
      @chart_color = options[:color]
      @chart_type = options[:type]
      @chart_angle = options[:angle]
    end
  end

  def max_value=(max_value)
    @max_value = max_value
    @max_value = nil if ['auto', :auto].include? @max_value
    @max_value = false if ['false', :false].include? @max_value
  end

  def min_value=(min_value)
    @min_value = min_value
    @min_value = nil if ['auto', :auto].include? @min_value
    @min_value = false if ['false', :false].include? @min_value
  end

  # auto sets the range if required
  # it also sets the axis_range if not defined
  def full_data_range(ds)
    return if @max_value == false

    ds.each_with_index do |mds, mds_index|
      # global limits override individuals. is this preferred?
      mds[:min_value] = @min_value if not @min_value.nil?
      mds[:max_value] = @max_value if not @max_value.nil?

      # TODO: can you have grouped stacked bars?
      
      if mds_index == 0 and @type == :bar
        # TODO: unless you specify a zero line (using chp or chds),
        #       the min_value of a bar chart is always 0.
        #mds[:min_value] ||= mds[:data].first.to_a.compact.min
        mds[:min_value] ||= 0
      end
      if (mds_index == 0 and @type == :bar and
          not grouped and mds[:data].first.is_a?(Array))
        totals = []
        mds[:data].each do |l|
          l.each_with_index do |v, index|
            next if v.nil?
            totals[index] ||= 0
            totals[index] += v
          end
        end
        mds[:max_value] ||= totals.compact.max
      else
        all = mds[:data].flatten.compact
        mds[:min_value] ||= all.min
        mds[:max_value] ||= all.max
      end
    end

    if not @axis_range
      @axis_range = ds.map{|mds| [mds[:min_value], mds[:max_value]]}
      if dimensions == 1 and (@type != :bar or not @horizontal)
        tmp = @axis_range.fetch(0, [])
        @axis_range[0] = @axis_range.fetch(1, [])
        @axis_range[1] = tmp
      end
    end
  end

  def number_visible
    n = 0
    axis_set.each do |mds|
      return n.to_s if mds[:invisible] == true
      if mds[:data].first.is_a?(Array)
        n += mds[:data].length
      else
        n += 1
      end
    end
    ""
  end

  # Turns input into an array of axis hashes, dependent on the chart type
  def convert_dataset(ds)
    if dimensions == 2
      # valid inputs include:
      # an array of >=2 arrays, or an array of >=2 hashes
      ds = ds.map do |d|
        d.is_a?(Hash) ? d : {:data => d}
      end
    elsif dimensions == 1
      # valid inputs include:
      # a hash, an array of data, an array of >=1 array, or an array of >=1 hash
      if ds.is_a?(Hash)
        ds = [ds]
      elsif not ds.first.is_a?(Hash)
        ds = [{:data => ds}]
      end
    end
    ds
  end

  def prepare_dataset
    @dataset = convert_dataset(data || [])
    full_data_range(@dataset)
  end

  def axis_set
    @dataset
  end

  def dataset
    datasets = []
    @dataset.each do |d|
      if d[:data].first.is_a?(Array)
        datasets += d[:data]
      else
        datasets << d[:data]
      end
    end
    datasets
  end

  def self.jstize(string)
    string.gsub(' ', '+').gsub(/\[|\{|\}|\||\\|\^|\[|\]|\`|\]/) {|c| "%#{c[0].to_s(16).upcase}"}
  end    
  # load all the custom aliases
  require 'gchart/aliases'
  
  protected
  
  # Returns the chart's generated PNG as a blob. (borrowed from John's gchart.rubyforge.org)
  def fetch
    open(query_builder) { |io| io.read }
  end

  # Writes the chart's generated PNG to a file. (borrowed from John's gchart.rubyforge.org)
  def write(io_or_file=@@file_name)
    return io_or_file.write(fetch) if io_or_file.respond_to?(:write)
    open(io_or_file, "w+") { |io| io.write(fetch) }
  end
  
  # Format
  
  def image_tag
    image = "<img"
    image += " id=\"#{@id}\"" if @id  
    image += " class=\"#{@class}\"" if @class      
    image += " src=\"#{query_builder(:html)}\""
    image += " width=\"#{@width}\""
    image += " height=\"#{@height}\""
    image += " alt=\"#{@alt}\""
    image += " title=\"#{@title}\"" if @title
    image += " />"
  end
  
  alias_method :img_tag, :image_tag
  
  def url
    query_builder
  end
  
  def file
    write
  end
  
  #
  def jstize(string)
    Gchart.jstize(string)
  end 
  
  private
  
  # The title size cannot be set without specifying a color.
  # A dark key will be used for the title color if no color is specified 
  def set_title
    title_params = "chtt=#{title}"
    unless (title_color.nil? && title_size.nil? )
      title_params << "&chts=" + (color, size = (@title_color || '454545'), @title_size).compact.join(',')
    end
    title_params
  end
  
  def set_size
    "chs=#{size}"
  end
  
  def set_data
    data = send("#{@encoding}_encoding")
    "chd=#{data}"
  end
  
  def set_colors
    bg_type = fill_type(@bg_type) || 's' if @bg_color
    chart_type = fill_type(@chart_type) || 's' if @chart_color
    
    "chf=" + {'bg' => fill_for(bg_type, @bg_color, @bg_angle), 'c' => fill_for(chart_type, @chart_color, @chart_angle)}.map{|k,v| "#{k},#{v}" unless v.nil?}.compact.join('|')      
  end
  
  # set bar, line colors
  def set_bar_colors
    @bar_colors = @bar_colors.join(',') if @bar_colors.is_a?(Array)
    "chco=#{@bar_colors}"
  end
  
  def set_country_codes
    @country_codes = @country_codes.join() if @country_codes.is_a?(Array)
    "chld=#{@country_codes}"
  end
  
  # set bar spacing
  # chbh=
  # <bar width in pixels>,
  # <optional space between bars in a group>,
  # <optional space between groups>
  def set_bar_width_and_spacing
    width_and_spacing_values = case @bar_width_and_spacing
    when String
      @bar_width_and_spacing
    when Array
      @bar_width_and_spacing.join(',')
    when Hash
      width = @bar_width_and_spacing[:width] || 23
      spacing = @bar_width_and_spacing[:spacing] || 4
      group_spacing = @bar_width_and_spacing[:group_spacing] || 8
      [width,spacing,group_spacing].join(',')
    else
      @bar_width_and_spacing.to_s
    end
    "chbh=#{width_and_spacing_values}"
  end
  
  def set_range_markers
    markers = case @range_markers
    when Hash
      set_range_marker(@range_markers)
    when Array
      range_markers.collect{|marker| set_range_marker(marker)}.join('|')
    end
    "chm=#{markers}"
  end
  
  def set_range_marker(options)
    orientation = ['vertical', 'Vertical', 'V', 'v', 'R'].include?(options[:orientation]) ? 'R' : 'r'
    "#{orientation},#{options[:color]},0,#{options[:start_position]},#{options[:stop_position]}#{',1' if options[:overlaid?]}"  
  end
  
  def fill_for(type=nil, color='', angle=nil)
    unless type.nil? 
      case type
        when 'lg'
          angle ||= 0
          color = "#{color},0,ffffff,1" if color.split(',').size == 1
          "#{type},#{angle},#{color}"
        when 'ls'
          angle ||= 90
          color = "#{color},0.2,ffffff,0.2" if color.split(',').size == 1
          "#{type},#{angle},#{color}"
        else
          "#{type},#{color}"
        end
    end
  end
  
  # A chart can have one or many legends. 
  # Gchart.line(:legend => 'label')
  # or
  # Gchart.line(:legend => ['first label', 'last label'])
  def set_legend
    return set_labels if @type == :pie || @type == :pie_3d || @type == :meter
    
    if @legend.is_a?(Array)
      "chdl=#{@legend.map{|label| "#{CGI::escape(label)}"}.join('|')}"
    else
      "chdl=#{@legend}"
    end
    
  end
  
  def set_labels
     if @legend.is_a?(Array)
        "chl=#{@legend.map{|label| "#{label}"}.join('|')}"
      else
        "chl=#{@legend}"
      end
  end
  
  def set_axis_with_labels
    @axis_with_labels = @axis_with_labels.join(',') if @axis_with_labels.is_a?(Array)
    "chxt=#{@axis_with_labels}"
  end
  
  def set_axis_labels
    if axis_labels.is_a?(Array)
      labels_arr = axis_labels.enum_with_index.map{|labels,index| [index,labels]}
    elsif axis_labels.is_a?(Hash)
      labels_arr = axis_labels.to_a
    end
    labels_arr.map! do |index,labels|
      if labels.is_a?(Array)
        "#{index}:|#{labels.to_a.join('|')}"
      else
        "#{index}:|#{labels}"
      end
    end
    "chxl=#{labels_arr.join('|')}"
  end
  
  # http://code.google.com/apis/chart/labels.html#axis_range
  # Specify a range for axis labels
  def set_axis_range
    # a passed axis_range should look like:
    # [[10,100]] or [[10,100,4]] or [[10,100], [20,300]]
    # in the second example, 4 is the interval 
    if axis_range && axis_range.respond_to?(:each) && axis_range.first.respond_to?(:each)
     'chxr=' + axis_range.enum_for(:each_with_index).map{|range, index| [index, range[0], range[1], range[2]].compact.join(',')}.join("|")
    else
      nil
    end
  end
  
  def set_geographical_area
    "chtm=#{@geographical_area}"
  end
  
  def set_type
    case @type
      when :line
        "cht=lc"
      when :line_xy
        "cht=lxy"
      when :bar
        "cht=b" + (horizontal? ? "h" : "v") + (grouped? ? "g" : "s")
      when :pie_3d
        "cht=p3"
      when :pie
        "cht=p"
      when :venn
        "cht=v"
      when :scatter
        "cht=s"
      when :sparkline
        "cht=ls"
      when :meter
        "cht=gom"
      when :map
        "cht=t"
      end
  end
  
  def fill_type(type)
    case type
    when 'solid'
      's'
    when 'gradient'
      'lg'
    when 'stripes'
      'ls'
    end
  end

  def encode_scaled_dataset chars, nil_char
    dsets = []
    axis_set.each do |ds|
      if @max_value != false
        range = ds[:max_value] - ds[:min_value]
        range = 1 if range == 0
      end
      if not ds[:data].first.is_a?(Array)
        datasets = [ds[:data]]
      else
        datasets = ds[:data]
      end
      datasets.each do |l|
        dsets << l.map do |number|
          if number.nil?
            nil_char
          else
            if not range.nil?
              number = chars.size * (number - ds[:min_value]) / range
              number = [number, chars.size - 1].min
            end
            chars[number.to_i]
          end
        end.join
      end
    end
    dsets.join(',')
  end

  # http://code.google.com/apis/chart/#simple
  # Simple encoding has a resolution of 62 different values. 
  # Allowing five pixels per data point, this is sufficient for line and bar charts up
  # to about 300 pixels. Simple encoding is suitable for all other types of chart regardless of size.
  def simple_encoding
    "s" + number_visible + ":" + encode_scaled_dataset(@@simple_chars, '_')
  end

  # http://code.google.com/apis/chart/#text
  # Text encoding with data scaling lets you specify arbitrary positive or
  # negative floating point numbers, in combination with a scaling parameter
  # that lets you specify a custom range for your chart. This chart is useful
  # when you don't want to worry about limiting your data to a specific range,
  # or do the calculations to scale your data down or up to fit nicely inside
  # a chart.
  #
  # Valid values range from (+/-)9.999e(+/-)100, and only four non-zero digits are supported (that is, 123400, 1234, 12.34, and 0.1234 are valid, but 12345, 123.45 and 123400.5 are not).
  #
  # This encoding is not available for maps.
  #
  def text_encoding
    chds = axis_set.map{ |ds| "#{ds[:min_value]},#{ds[:max_value]}" }.join(",")
    "t" + number_visible + ":" + dataset.map{ |ds| ds.join(',') }.join('|') + "&chds=" + chds
  end

  # http://code.google.com/apis/chart/#extended
  # Extended encoding has a resolution of 4,096 different values 
  # and is best used for large charts where a large data range is required.
  def extended_encoding
    "e" + number_visible + ":" + encode_scaled_dataset(@@ext_pairs, '__')
  end

  def query_builder(options="")
    prepare_dataset
    query_params = instance_variables.map do |var|
      case var
      when '@data'
        set_data unless @data == []  
      # Set the graph size  
      when '@width'
        set_size unless @width.nil? || @height.nil?
      when '@type'
        set_type
      when '@title'
        set_title unless @title.nil?
      when '@legend'
        set_legend unless @legend.nil?
      when '@bg_color'
        set_colors
      when '@chart_color'
        set_colors if @bg_color.nil?
      when '@bar_colors'
        set_bar_colors
      when '@bar_width_and_spacing'
        set_bar_width_and_spacing
      when '@axis_with_labels'
        set_axis_with_labels
      when '@axis_range'
        set_axis_range if dataset
      when '@axis_labels'
        set_axis_labels
      when '@range_markers'
        set_range_markers
      when '@geographical_area'
        set_geographical_area
      when '@country_codes'
        set_country_codes
      when '@custom'
        @custom
      end
    end.compact
    
    # Use ampersand as default delimiter
    unless options == :html
      delimiter = '&'
    # Escape ampersand for html image tags
    else
      delimiter = '&amp;'
    end
    
    jstize(@@url + query_params.join(delimiter))
  end
  
end
