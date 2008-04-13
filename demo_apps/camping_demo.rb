 # Basic Camping demo, taken from Why's official Camping site

 require 'rubygems'
 require 'camping'

 Camping.goes :CampingDemo

 module CampingDemo::Controllers

   # The root slash shows the `index' view.
   class Index < R '/'
     def get
       render :index 
     end
   end

   # Any other page name gets sent to the view
   # of the same name.
   #
   #   /index -> Views#index
   #   /sample -> Views#sample
   #
   class Page < R '/(\w+)'
     def get(page_name)
       render page_name
     end
   end

 end

 module CampingDemo::Views

   # If you have a `layout' method like this, it
   # will wrap the HTML in the other methods.  The
   # `self << yield' is where the HTML is inserted.
   def layout
     html do
       title { 'My HomePage' }
       body { self << yield }
     end
   end

   # The `index' view.  Inside your views, you express
   # the HTML in Ruby.  See http://code.whytheluckystiff.net/markaby/.
   def index
     p 'Hi my name is Charles.'
     p 'Here are some links:'
     ul do
      li { a 'Google', :href => 'http://google.com' }
      li { a 'A sample page', :href => '/sample' }
     end
   end

   # The `sample' view.
   def sample
     p 'A sample page'
   end
 end
