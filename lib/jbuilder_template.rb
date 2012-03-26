class JbuilderTemplate < Jbuilder
  def self.encode(context)
    new(context)._tap { |jbuilder| yield jbuilder }.target
  end

  def initialize(context)
    @context = context
    @target = ActiveSupport::SafeBuffer.new
    super()
  end

  def partial!(partial_name, options = {})
    output_buffer = ActiveSupport::SafeBuffer.new
    @context.render(partial_name, options.merge(:json => self, :partial_output_buffer => output_buffer))
    @attributes = ActiveSupport::JSON.decode output_buffer
  end

  def target
    @target
  end

  def target!
    @target.replace ActiveSupport::JSON.encode @attributes
  end

  def set!(key, value)
    super
    target!
  end

  def child!
    super
    target!
  end

  private
    def _new_instance
      __class__.new(@context)
    end
end

class JbuilderHandler < ActionView::TemplateHandler
  include ActionView::Template::Handlers::Compilable

  self.default_format = Mime::JSON

  def compile(template)
    %{
      self.output_buffer = ActiveSupport::SafeBuffer.new

      self.output_buffer << if defined?(json)
                              self.output_buffer = json.target
                              #{template.source}
                            else
                              JbuilderTemplate.encode(self) do |json|
                                self.output_buffer = json.target
                                #{template.source}
                              end
                            end

      partial_output_buffer << self.output_buffer if defined?(partial_output_buffer)
      self.output_buffer
    }
  end
end

ActionView::Template.register_template_handler :jbuilder, JbuilderHandler
