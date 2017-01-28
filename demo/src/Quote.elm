module Quote exposing (..)

import Http
import Json.Decode exposing (Decoder, string)
import Json.Decode.Pipeline exposing (required, decode, hardcoded)


type alias Quote =
    { lang : String
    , text : String
    , author : String
    }


quoteDecoder : String -> Decoder Quote
quoteDecoder lang =
    decode Quote
        |> hardcoded lang
        |> required "quoteText" string
        |> required "quoteAuthor" string


quoteRequest : String -> Http.Request Quote
quoteRequest lang =
    quoteDecoder lang
        |> Http.get
            ("http://api.forismatic.com/api/1.0/?method=getQuote&format=json&lang="
                ++ lang
            )


formatQuote : String -> Quote -> String
formatQuote lineBreak quote =
    quote.text ++ lineBreak ++ "--" ++ quote.author