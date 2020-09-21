(* BSD 3-Clause License

   Copyright (c) 2020, Anurag Soni All rights reserved.

   Redistribution and use in source and binary forms, with or without modification, are
   permitted provided that the following conditions are met:

   1. Redistributions of source code must retain the above copyright notice, this list of
   conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright notice, this list
   of conditions and the following disclaimer in the documentation and/or other materials
   provided with the distribution.

   3. Neither the name of the copyright holder nor the names of its contributors may be
   used to endorse or promote products derived from this software without specific prior
   written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
   EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
   THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
   PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
   STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
   THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. *)

let write_cstr f s =
  Faraday.write_string f s;
  Faraday.write_uint8 f 0

module Types = struct
  module Optional_string = struct
    type t = string

    let empty = ""
    let of_string = Fun.id
    let to_string = Fun.id
    let is_empty t = t = ""
    let length = String.length
  end

  module Oid = struct
    type t = Int32.t

    let of_int32 = Fun.id
    let of_int_exn = Int32.of_int
    let to_int32 = Fun.id
  end

  module Format_code = struct
    type t =
      [ `Text
      | `Binary
      ]

    let of_int = function
      | 0 -> Some `Text
      | 1 -> Some `Binary
      | _ -> None

    let to_int = function
      | `Text -> 0
      | `Binary -> 1
  end
end

open Types

module Auth = struct
  module Md5 = struct
    (* https://www.postgresql.org/docs/12/protocol-flow.html#id-1.10.5.7.3 *)
    let hash ~username ~password ~salt =
      let digest = Digest.string (password ^ username) in
      let hex = Digest.to_hex digest in
      let digest = Digest.string (hex ^ salt) in
      let hex = Digest.to_hex digest in
      Printf.sprintf "md5%s" hex
  end
end

type protocol_version = V3_0

let write_protocol_version f = function
  | V3_0 ->
    Faraday.BE.write_uint16 f 3;
    Faraday.BE.write_uint16 f 0

module Frontend = struct
  module Startup_message = struct
    let ident = None

    type t =
      { user : string
      ; database : string option
      ; protocol_version : protocol_version
      }

    let make ~user ?database () = { user; database; protocol_version = V3_0 }

    let write f { user; database; protocol_version } =
      write_protocol_version f protocol_version;
      write_cstr f "user";
      write_cstr f user;
      Option.iter
        (fun d ->
          write_cstr f "database";
          write_cstr f d)
        database

    let size { user; database; _ } =
      let user_len = 4 + 1 + String.length user + 1 in
      let database_len =
        match database with
        | None -> 0
        | Some d -> 8 + 1 + String.length d + 1
      in
      4 + user_len + database_len
  end

  module Password_message = struct
    let ident = Some 'p'

    type t = Md5 of string

    let size (Md5 s) = String.length s + 1
    let write f (Md5 s) = write_cstr f s
  end

  module Parse = struct
    let ident = Some 'P'

    type t =
      { name : Optional_string.t
      ; statement : string
      ; oids : Oid.t Array.t
      }

    let size { name; statement; oids } =
      Optional_string.length name
      + 1
      + String.length statement
      + 1
      + 2
      + (Array.length oids * 4)

    let write f { name; statement; oids } =
      write_cstr f (Optional_string.to_string name);
      write_cstr f statement;
      Faraday.BE.write_uint16 f (Array.length oids);
      Array.iter (fun oid -> Faraday.BE.write_uint32 f (Oid.to_int32 oid)) oids
  end

  module Bind = struct
    let ident = Some 'B'

    type parameter =
      { format_code : Format_code.t
      ; parameter : string option
      }

    type t =
      { destination : Optional_string.t
      ; statement : Optional_string.t
      ; parameters : parameter Array.t
      ; result_formats : Format_code.t Array.t
      }

    let size { destination; statement; parameters; result_formats } =
      let param_len = Array.length parameters in
      Optional_string.length destination
      + 1
      + Optional_string.length statement
      + 1
      + 2
      + (param_len * 2)
      + 2
      + Array.fold_left
          (fun acc { parameter; _ } ->
            acc + 4 + String.length (Option.value parameter ~default:""))
          0
          parameters
      + 2
      + (Array.length result_formats * 2)

    let write f { destination; statement; parameters; result_formats } =
      write_cstr f (Optional_string.to_string destination);
      write_cstr f (Optional_string.to_string statement);
      Faraday.BE.write_uint16 f (Array.length parameters);
      Array.iter
        (fun { format_code; _ } ->
          Faraday.BE.write_uint16 f (Format_code.to_int format_code))
        parameters;
      Faraday.BE.write_uint16 f (Array.length parameters);
      Array.iter
        (fun { parameter; _ } ->
          let len =
            match parameter with
            | None -> -1
            | Some v -> String.length v
          in
          Faraday.BE.write_uint32 f (Int32.of_int len);
          Option.iter (Faraday.write_string f) parameter)
        parameters;
      Faraday.BE.write_uint16 f (Array.length result_formats);
      Array.iter
        (fun fmt -> Faraday.BE.write_uint16 f (Format_code.to_int fmt))
        result_formats
  end
end

module Writer = struct
  type t = { writer : Faraday.t }

  let create () = { writer = Faraday.create 0x1000 }

  module type Message = sig
    type t

    val ident : char option
    val size : t -> int
    val write : Faraday.t -> t -> unit
  end

  let write (type a) (module M : Message with type t = a) msg t =
    let header_length = if Option.is_none M.ident then 4 else 5 in
    Option.iter (fun c -> Faraday.write_char t.writer c) M.ident;
    Faraday.BE.write_uint32 t.writer (Int32.of_int @@ (M.size msg + header_length));
    M.write t.writer msg

  let startup t msg = write (module Frontend.Startup_message) msg t
  let password t msg = write (module Frontend.Password_message) msg t
  let parse t msg = write (module Frontend.Parse) msg t
  let bind t msg = write (module Frontend.Bind) msg t
end
