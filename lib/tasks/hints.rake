namespace :hints do
  desc "List hints still marked 'To Edit:' for the owner to review (R3)"
  task todo: :environment do
    I18n.backend.send(:init_translations) unless I18n.backend.initialized?
    walk = lambda do |node, path|
      case node
      when Hash then node.each { |k, v| walk.call(v, [ *path, k ]) }
      when String then puts "#{path.join('.')}: #{node}" if node.start_with?("To Edit:")
      end
    end
    walk.call(I18n.backend.send(:translations).dig(:en, :hints) || {}, [ "hints" ])
  end
end
