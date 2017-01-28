module Serverless.Plug.Private exposing (..)

import Array exposing (Array)
import Json.Encode as J
import Serverless.Conn exposing (..)
import Serverless.Conn.Types exposing (..)
import Serverless.Msg exposing (..)
import Serverless.Plug exposing (..)


firstIndexPath : IndexPath
firstIndexPath =
    Array.empty |> Array.push 0


type alias Options config model msg =
    { endpoint : msg
    , responsePort : J.Value -> Cmd (Msg msg)
    , pipeline : Pipeline config model msg
    }


applyPipeline :
    Options config model msg
    -> PlugMsg msg
    -> IndexDepth
    -> List (Cmd (Msg msg))
    -> Conn config model
    -> ( Conn config model, Cmd (Msg msg) )
applyPipeline opt plugMsg depth appCmdAcc conn =
    case plugMsg of
        PlugMsg indexPath msg ->
            case indexPath |> Array.get depth of
                Nothing ->
                    if appCmdAcc |> List.isEmpty then
                        conn |> lostIt opt
                    else
                        ( conn, Cmd.batch appCmdAcc )

                Just index ->
                    case opt.pipeline |> Array.get index of
                        Just plug ->
                            applyPipelineHelper
                                opt
                                appCmdAcc
                                plug
                                index
                                indexPath
                                depth
                                msg
                                conn

                        Nothing ->
                            if appCmdAcc |> List.isEmpty then
                                conn |> lostIt opt
                            else
                                ( conn, Cmd.batch appCmdAcc )


applyPipelineHelper :
    Options config model msg
    -> List (Cmd (Msg msg))
    -> Plug config model msg
    -> Index
    -> IndexPath
    -> IndexDepth
    -> msg
    -> Conn config model
    -> ( Conn config model, Cmd (Msg msg) )
applyPipelineHelper opt appCmdAcc plug index indexPath depth msg conn =
    let
        ( newConn, cmd, appCmd ) =
            conn |> applyPlug opt appCmdAcc index indexPath depth plug msg

        newAppCmds =
            [ cmd
                |> Cmd.map (PlugMsg indexPath)
                |> Cmd.map (HandlerMsg conn.req.id)
            , appCmd
            ]
                |> cmdReduce

        newAppCmdAcc =
            List.append appCmdAcc newAppCmds
                |> cmdReduce
    in
        case newConn.resp of
            Unsent _ ->
                case newConn.pipelineState of
                    Processing ->
                        newConn
                            |> applyPipeline
                                opt
                                (PlugMsg
                                    (indexPath |> Array.set depth (index + 1))
                                    opt.endpoint
                                )
                                depth
                                newAppCmdAcc

                    Paused _ ->
                        if newAppCmdAcc |> List.isEmpty then
                            conn |> lostIt opt
                        else
                            ( newConn, Cmd.batch newAppCmdAcc )

            Sent ->
                if newAppCmdAcc |> List.isEmpty then
                    conn |> lostIt opt
                else
                    ( newConn, Cmd.batch newAppCmdAcc )


applyPlug :
    Options config model msg
    -> List (Cmd (Msg msg))
    -> Index
    -> IndexPath
    -> IndexDepth
    -> Plug config model msg
    -> msg
    -> Conn config model
    -> ( Conn config model, Cmd msg, Cmd (Msg msg) )
applyPlug opt appCmdAcc index indexPath depth plug msg conn =
    case plug of
        Plug transform ->
            let
                ( newConn, cmd ) =
                    ( conn |> transform, Cmd.none )
            in
                ( newConn, cmd, Cmd.none )

        Loop update ->
            let
                ( newConn, cmd ) =
                    conn |> update msg
            in
                ( newConn, cmd, Cmd.none )

        Router router ->
            let
                ( newConn, appCmd ) =
                    conn
                        |> applyRouter
                            opt
                            appCmdAcc
                            index
                            indexPath
                            depth
                            router
                            msg
            in
                ( newConn, Cmd.none, appCmd )


applyRouter :
    Options config model msg
    -> List (Cmd (Msg msg))
    -> Index
    -> IndexPath
    -> IndexDepth
    -> (Conn config model -> Pipeline config model msg)
    -> msg
    -> Conn config model
    -> ( Conn config model, Cmd (Msg msg) )
applyRouter opt appCmdAcc index indexPath depth router msg conn =
    let
        newOpt =
            conn
                |> router
                |> Options opt.endpoint opt.responsePort
    in
        if newOpt.pipeline |> Array.isEmpty then
            conn
                |> status (Code 500)
                |> body (TextBody "router yielded empty pipeline")
                |> send opt.responsePort
        else
            let
                newIndexPath =
                    if (indexPath |> Array.length) < depth + 2 then
                        indexPath |> Array.push 0
                    else
                        indexPath
            in
                conn
                    |> applyPipeline
                        newOpt
                        (PlugMsg
                            newIndexPath
                            msg
                        )
                        (depth + 1)
                        appCmdAcc


cmdReduce : List (Cmd msg) -> List (Cmd msg)
cmdReduce =
    List.filter (\cmd -> cmd /= Cmd.none)


lostIt :
    Options config model msg
    -> Conn config model
    -> ( Conn config model, Cmd (Msg msg) )
lostIt opt conn =
    conn
        |> status (Code 500)
        |> body (TextBody "processing fell off the pipeline, ouch")
        |> send opt.responsePort