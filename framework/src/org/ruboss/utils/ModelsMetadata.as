package org.ruboss.utils {
  import flash.net.registerClassAlias;
  import flash.utils.Dictionary;
  import flash.utils.describeType;
  import flash.utils.getQualifiedClassName;
  
  import mx.collections.ArrayCollection;
  
  public class ModelsMetadata {
    
    public var models:Array;
    
    public var controllers:Dictionary;
    
    public var refs:Dictionary;

    public var fqns:Dictionary;
    
    public var types:Dictionary;
    
    public var names:Dictionary;
    
    public var indexed:Dictionary;
    
    public var shown:Dictionary;
    
    public var waiting:Dictionary;
    
    public var pages:Dictionary;

    public var eager:Dictionary;

    public var lazy:Dictionary;
    
    public var hmts:Dictionary;

    public function ModelsMetadata(models:Array) {
      this.models = models;
      
      controllers = new Dictionary;
      refs = new Dictionary;
      fqns = new Dictionary;
      types = new Dictionary;
      names = new Dictionary;
      
      indexed = new Dictionary;
      shown = new Dictionary;
      waiting = new Dictionary;
      
      pages = new Dictionary;
      
      eager = new Dictionary;
      lazy = new Dictionary;
      hmts = new Dictionary;
      
      for each (var model:Class in models) {
        var controllerName:String = RubossUtils.getResourceName(model);
        var fqn:String = getQualifiedClassName(model);

        // don't store any metadata for a model that doesn't have a controller
        if (RubossUtils.isEmpty(controllerName)) {
          throw new Error("model: " + model + " with qualified name: " + fqn +
            " doesn't have a valid [Resource(name='*')] annotation.");
        }
        
        var modelName:String = fqn.split("::")[1] as String;
        
        // this is what model names would look like after 
        // camel-casing variable names we get from RoR
        var defaultSingleName:String = RubossUtils.lowerCaseFirst(modelName);
        var defaultPluralName:String = RubossUtils.toCamelCase(controllerName);
        
        refs[fqn] = new Dictionary;
        types[model] = fqn;
        types[fqn] = model;

        fqns[controllerName] = fqn;        
        fqns[modelName] = fqn;
        fqns[defaultSingleName] = fqn;
        fqns[defaultPluralName] = fqn;
        
        names[fqn] = {single: defaultSingleName, plural: defaultPluralName};
        
        controllers[fqn] = controllerName;
        
        lazy[fqn] = new Array;
        eager[fqn] = new Array;

        pages[fqn] = -1;
        
        shown[fqn] = new ArrayCollection;

        registerClassAlias(fqn.replace("::","."), model);
      }
      
      // once we have set up the core data structures we need another pass to compute 
      // dependencies and find has_many(:through) relationships if any
      models.forEach(function(elm:Class, index:int, array:Array):void {
        extractMetadata(elm);
      });
    }

    /**
     * Resets model metadata.
     *  
     * @param object can be a model class or specific model instance
     */
    public function reset(object:Object = null):void {
      // if no argument is specified, reset everything
      if (object == null) {
        indexed = new Dictionary;
        for (var model:String in shown) {
          shown[model] = new ArrayCollection;
        }
      } else {
        var fqn:String = getQualifiedClassName(object);

        if (object is Class) {
          indexed[fqn] = false;
        } else {
          var items:ArrayCollection = shown[fqn] as ArrayCollection;
          var offset:int = items.getItemIndex(object["id"]);
          if (offset > -1) items.removeItemAt(offset);     
        }
      }  
    }
    
    private function extractMetadata(model:Class):void {
      var fqn:String = types[model];
      for each (var node:XML in describeType(model)..accessor) {
        try {
          // we are only interested in [BelongsTo], [HasMany] and [HasOne] annotated nodes
          // that refer to other valid models
          if (!RubossUtils.isBelongsTo(node) && !RubossUtils.isHasMany(node) && !RubossUtils.isHasOne(node)) continue;
          
          // determine what a well-formed reference name should look like, this is typically
          // driven by class name = declarations of type project:Project are well-formed
          // in other words if localName == keyName, then it's well-formed
          var refType:String = node.@type;
          var refName:String = node.@name;
          var referAs:String;
          
          var dependencies:Array = new Array;
          var descriptor:XML;
          
          if (!types[refType]) {
            // we can try to figure out the type by the name of the variable
            refType = fqns[refName];
            
            // it could be a ModelsCollection or a polymorphic type Object, or interface, etc.
            // we need more info to figure out what type of objects are represented by this variable
            if (RubossUtils.isBelongsTo(node)) {
              descriptor = RubossUtils.getAttributeAnnotation(node, "BelongsTo")[0];
              if (descriptor) {
                referAs = descriptor.arg.(@key == "referAs").@value.toString();
              }
            } else if (RubossUtils.isHasOne(node)) {
              descriptor = RubossUtils.getAttributeAnnotation(node, "HasOne")[0];
            } else if (RubossUtils.isHasMany(node)) {
              descriptor = RubossUtils.getAttributeAnnotation(node, "HasMany")[0];
              if (refName == "children") {
                refType = fqn;
              }
              // hook up N-N = has_many(:through) relationships
              extractHasManyThroughRelationships(node, descriptor, fqn);
            }
            
            if (descriptor) {
              var implicitType:String = descriptor.arg.(@key == "type").@value.toString();
              if (fqns[implicitType]) {
                refType = fqns[implicitType];
              }
            }       
          } else {
            // it's a [BelongsTo] or [HasOne] annotation that explicitly specifies the type
            if (RubossUtils.isBelongsTo(node)) {
              descriptor = RubossUtils.getAttributeAnnotation(node, "BelongsTo")[0];
              if (descriptor) {
                referAs = descriptor.arg.(@key == "referAs").@value.toString();
              }
            }       
          }

          if (RubossUtils.isBelongsTo(node)) extractDependencies(dependencies, node, descriptor, refType);

          refs[fqn][refName] = {type: refType, referAs: referAs};
          
          for each (var dependency:String in dependencies) {
            if (controllers[dependency] && dependency != fqn && (eager[fqn] as Array).indexOf(dependency) == -1) {
              if (!RubossUtils.isLazy(node)) {
                (lazy[fqn] as Array).push(dependency);
              }
              (eager[fqn] as Array).push(dependency);
            }
          }
        } catch (e:Error) {
          
        }
      } 
    }
    
    private function extractDependencies(dependencies:Array, node:XML, descriptor:XML, defaultRefType:String):void {
      if (RubossUtils.isPolymorphicBelongsTo(node)) {
        for each (var shortName:String in descriptor.arg.(@key == "dependsOn").@value.toString().split(",")) {
          shortName = shortName.replace(/\s*/, "");
          var key:String = fqns[shortName];
          if (key != null) {
            dependencies.push(key);
          }
        }
      } else {
        dependencies.push(defaultRefType);
      }
    }
    
    private function extractHasManyThroughRelationships(node:XML, descriptor:XML, fqn:String):void {
      var value:String = descriptor.arg.(@key == "through").@value.toString();
      var refType:String = descriptor.arg.(@key == "type").@value.toString();
      if (!RubossUtils.isEmpty(value)) {
        var target:String = RubossUtils.toSnakeCase(value);
        var attribute:String = node.@name;

        if (hmts[target] == null) {
          hmts[target] = new Array;
        }
        (hmts[target] as Array).push({type: fqn, attribute: attribute, refType: refType});
      }
    }
  }
}