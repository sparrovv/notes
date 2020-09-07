```
title: Jackson scala module gotchas
description: Some intricacies of jackson-scala-module
published: false
tags: scala, json, jackson
```

Handling JSON serialization is one of the tasks that you don’t want to think too much about. It just should work without much of a hassle.

In scala, there are many libraries that handle JSON serialization. I didn't understand why that’s the case when I first started using the language. There was no canonical one, and it seemed odd coming from a dynamic language background like ruby and python.

Thankfully these days there are only few libraries that have a strong community around. And from what I’ve seen most of the new projects start with [circe](https://circe.github.io/circe/), which looks like a reasonable choice.

But what if you maintain a project that uses a different library and it doesn’t make sense to change?
I'm in this kind of situation. The project I'm maintaining uses [Jackson-scala-module](https://github.com/FasterXML/jackson-module-scala).

Jackson is a popular library on JVM and it has a good community around, which is defo a good thing. It's easy to start with, it handles case class serialization/de-serialization, but there are few things that you need to be aware of.

### How to Encode Scala Enums?

Out of the box, Enums serialization works, but the JSON document looks strange, and probably it’s not what you’re expecting. This behaviour is already deprecated, but if you don't use special annotation you will get something like this

```scala
val mapper = new ObjectMapper() with ScalaObjectMapper
mapper.registerModule(DefaultScalaModule)

def toJson[T](value: T): String = mapper.writeValueAsString(value) 
def fromJson[T](json: String)(implicit m: Manifest[T]): T = mapper.readValue[T](json)

object EnumStatus extends Enumeration {
  val Start = Value("start")
  val End = Value("end")
}

case class Foo(status: EnumStatus.Value)
toJson(Foo(EnumStatus.Start)) 

//output: {"status":{"enumClass":"...$EnumStatus","value":"start"}}
```

To get your Enums serialized with correct values there’s some boilerplate needed and it's well explained in the project's [wiki](https://github.com/FasterXML/jackson-module-scala/wiki/Enumerations)


### How to Encode Sealed Traits

Even though scala has enum type in the stdlib, the way to represent a finite set of entities is by using sealed traits.
Jackson doesn't support that out of the box. You will get an exception if you try to serialize sealed trait type, so to overcome that you need to define serializer and deserializer. It's cumbersome but I didn't find a better way.


```scala
@JsonSerialize(using = classOf[StatusSerializer])
@JsonDeserialize(using = classOf[StatusDeserializer])
sealed trait Status{
  def name:String
}
object Start extends Status {
  override val name = "start"
}
object End extends Status {
  override val name = "end"
}

class StatusSerializer extends JsonSerializer[Status] {
  override def serialize( w: Status, json: JsonGenerator, provider: SerializerProvider ): Unit = {
    json.writeString(w.name)
  }
}

class StatusDeserializer extends JsonDeserializer[Status] {
  override def deserialize(p: JsonParser, ctxt: DeserializationContext): Status = {
    val node: JsonNode = p.getCodec.readTree(p)
    val s: String = node.asText()
    s match {
      case Start.name => Start
      case End.name => End
      case _ => throw new IllegalArgumentException(
        s"[$s] is not a valid value for Status"
      )
    }
  }
}
```

#### basic types de-serialization when in Option container

Let's assume you have a simple case class 

```scala
case class IntInOption(
    score: Option[Int]
)

val jsonWithIntAsStr =
    """
    |{"score": "1"}
    |""".stripMargin.stripLineEnd

```
You would expect that after deserializing this will be true, right?

```
val intInOptionDes = JsonMapper.fromJson[IntInOption](jsonWithIntAsStr)

intInOptionDes == IntInOption(Some(1))
//false
```

But it's not. You don't get any exception, and even under some more in-depth investigation it all looks the same, but equality doesn't match.
In this particular example, JSON `score` field is in `""` so it's a string. Jackson can coerce a string type if it looks like a number and you expect a numeric type. The problem is more that it's in Option container and then Jackson needs more information.

There is an easy fix and the explanation is also the project's wiki [deserializing option ints](https://github.com/FasterXML/jackson-module-scala/wiki/FAQ#deserializing-optionint-and-other-primitive-challenges).

You need to add an annotation:

```scala
case class IntInOption(
    @JsonDeserialize(contentAs = classOf[java.lang.Integer])
    score: Option[Int]
)
```

### Fields that are serialized and you don't even know about this

Another unexpected thing that was confusing is that some methods are serialized to JSON even if they are not `val/var`.
If your case class has methods like `def isThisWorkingOrNot:Boolean` then the output JSON document will have {thisWorkingOrNot:true}

```scala
case class Bar(score: Option[Int], status: String ) {
  def isThisWorkingOrNot:Boolean = true

  @JsonIgnore
  def isThisWorkingOrNot2:Boolean = false
}

val bar = Bar(Some(1), "start")
println(JsonMapper.toJson(bar))

# {"score":1,"status":"start","thisWorkingOrNot":true}
```

You can annotate it with `@JsonIgnore` to get rid of it or check out other ways: https://www.baeldung.com/jackson-ignore-properties-on-serialization

### Other useful annotations

- @JsonProperty("my_val")

Useful when you want to use a different name in JSON document than what you have in your class or when you want to make some method serializable.

### Useful Configuration

Depending on your requirements these are handy mapper configurations:

```scala
mapper.configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false)
```

Useful when you don't own JSON documents and they can evolve outside of your system.

## References

- Runnable worksheets prepared mainly for this post: https://github.com/sparrovv/scala-playground/tree/master/scala-scripts/src/main/scala/jackson_worksheet
- Many good examples of how to use jackson-scala-module: https://github.com/seahrh/jackson-scala-example