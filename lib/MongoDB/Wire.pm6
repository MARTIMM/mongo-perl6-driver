use v6;

use BSON::Document;
use MongoDB;
use MongoDB::CollectionIF;
use MongoDB::Header;
use MongoDB::Object-store;

package MongoDB {

  class Wire {

    #---------------------------------------------------------------------------
    #
    method query (
      MongoDB::CollectionIF $collection! where .^name eq 'MongoDB::Collection',
      BSON::Document:D $qdoc, $projection?, :$flags, :$number-to-skip,
      :$number-to-return, Str :$server-ticket
      --> BSON::Document
    ) {
      # Must clone the document otherwise the MongoDB::Header will be added
      # to the $qdoc even when the copy trait is used.
      #
      my BSON::Document $d = $qdoc.clone;
      $d does MongoDB::Header;
      my BSON::Document $result;

      my Bool $write-operation = False;
      my $client;
      my $socket;

      try {
        $client = $collection.database.client;

        # Check if the server ticket is defined and thus a server is reserved
        # for this communication.
        #
        fatal-message("No server available") unless ?$server-ticket;

        $write-operation = ($d.find-key(0) ~~ any(<insert update delete>));
#say "Need master for {$d.find-key(0)} $write-operation";
        my $full-collection-name = $collection.full-collection-name;

        ( my Buf $encoded-query, my Int $request-id) = $d.encode-query(
          $full-collection-name, $projection,
          :$flags, :$number-to-skip, :$number-to-return
        );

        $socket = $client.store.get-stored-object($server-ticket).get-socket;
        $socket.send($encoded-query);

        # Read 4 bytes for int32 response size
        #
        my Buf $size-bytes = $socket.receive(4);
        if $size-bytes.elems == 0 {
          # Try again
          #
          $size-bytes = $socket.receive(4);
          fatal-message("No response from server") if $size-bytes.elems == 0;
        }

        if $size-bytes.elems < 4 {
          # Try to get the rest of it
          #
          $size-bytes.push($socket.receive(4 - $size-bytes.elems));
          fatal-message("Response corrupted") if $size-bytes.elems < 4;
        }

        my Int $response-size = decode-int32( $size-bytes, 0) - 4;

        # Receive remaining response bytes from socket. Prefix it with the
        # already read bytes and decode. Return the resulting document.
        #
        my Buf $server-reply = $size-bytes ~ $socket.receive($response-size);
        if $server-reply.elems < $response-size + 4 {
          $server-reply.push($socket.receive($response-size));
          fatal-message("Response corrupted") if $server-reply.elems < $response-size + 4;
        }

        $result = $d.decode-reply($server-reply);

        # Assert that the request-id and response-to are the same
        #
        fatal-message("Id in request is not the same as in the response")
          unless $request-id == $result<message-header><response-to>;


        # Catch all thrown exceptions and take out the server if needed
        #
        CATCH {
          when MongoDB::Message {
            $client.take-out-server($server-ticket);
          }

          default {
            when Str {
              warn-message($_);
              $client.take-out-server($server-ticket);
            }

            when Exception {
              warn-message(.message);
              $client.take-out-server($server-ticket);
            }
          }

        }
      }

      $socket.close if $socket.defined;
      return $result;
    }

    #---------------------------------------------------------------------------
    #
    method get-more ( $cursor, Str:D :$server-ticket --> BSON::Document ) {

      my BSON::Document $d .= new;
      $d does MongoDB::Header;
      my $client;
      my $socket;
      my BSON::Document $result;

      try {

        ( my Buf $encoded-get-more, my Int $request-id) = $d.encode-get-more(
          $cursor.full-collection-name, $cursor.id
        );

        $client = $cursor.client;

        fatal-message("No server available") unless ?$server-ticket;
        $socket = $client.store.get-stored-object($server-ticket).get-socket;
        $socket.send($encoded-get-more);

        # Read 4 bytes for int32 response size
        #
        my Buf $size-bytes = $socket.receive(4);
        if $size-bytes.elems == 0 {
          # Try again
          #
          $size-bytes = $socket.receive(4);
          fatal-message("No response from server") if $size-bytes.elems == 0;
        }

        if $size-bytes.elems < 4 {
          # Try to get the rest of it
          #
          $size-bytes.push($socket.receive(4 - $size-bytes.elems));
          fatal-message("Response corrupted") if $size-bytes.elems < 4;
        }

        my Int $response-size = decode-int32( $size-bytes, 0) - 4;

        # Receive remaining response bytes from socket. Prefix it with the already
        # read bytes and decode. Return the resulting document.
        #
        my Buf $server-reply = $size-bytes ~ $socket.receive($response-size);
        if $server-reply.elems < $response-size + 4 {
          $server-reply.push($socket.receive($response-size));
          fatal-message("Response corrupted") if $server-reply.elems < $response-size + 4;
        }

        $result = $d.decode-reply($server-reply);
  # TODO check if cursorID matches (if present)

        # Assert that the request-id and response-to are the same
        #
        fatal-message("Id in request is not the same as in the response")
          unless $request-id == $result<message-header><response-to>;


        # Catch all thrown exceptions and take out the server if needed
        #
        CATCH {
          when MongoDB::Message {
            $client.take-out-server($server-ticket);
          }

          default {
            when Str {
              warn-message($_);
              $client.take-out-server($server-ticket);
            }

            when Exception {
              warn-message(.message);
              $client.take-out-server($server-ticket);
            }
          }
        }
      }

      $socket.close if $socket.defined;
      return $result;
    }

    #---------------------------------------------------------------------------
    #
    method kill-cursors (
      @cursors where $_.elems > 0,
      Str:D :$server-ticket
    ) {

      my BSON::Document $d .= new;
      $d does MongoDB::Header;
      my $client;
      my $socket;

      # Gather the ids only when they are non-zero.i.e. still active.
      #
      my Buf @cursor-ids;
      for @cursors -> $cursor {
        @cursor-ids.push($cursor.id) if [+] $cursor.id.list;
      }

      # Kill the cursors if found any
      #
      $client = @cursors[0].client;

      try {
        fatal-message("No server available") unless ?$server-ticket;
        $socket = $client.store.get-stored-object($server-ticket).get-socket;

        if +@cursor-ids {
          ( my Buf $encoded-kill-cursors,
            my Int $request-id
          ) = $d.encode-kill-cursors(@cursor-ids);

          $socket.send($encoded-kill-cursors);
        }


        # Catch all thrown exceptions and take out the server if needed
        #
        CATCH {
          when MongoDB::Message {
            $client.take-out-server($server-ticket);
          }

          default {
            when Str {
              warn-message($_);
              $client.take-out-server($server-ticket);
            }

            when Exception {
              warn-message(.message);
              $client.take-out-server($server-ticket);
            }
          }
        }
      }

      $socket.close if $socket.defined;
    }
  }
}



=finish

#`{{
    #---------------------------------------------------------------------------
    #
    method OP_INSERT (
      $collection, Int $flags, *@documents --> Nil
    ) is DEPRECATED('OP-INSERT') {

      self.OP-INSERT( $collection, $flags, @documents);
    }

    method OP-INSERT ( $collection, Int $flags, *@documents --> Nil ) {
      # http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-OPINSERT

      my Buf $B-OP-INSERT = [~]

        # int32 flags
        # bit vector
        #
        encode-int32($flags),

        # cstring fullCollectionName
        # "dbname.collectionname"
        #
        encode-cstring($collection.full.collection-name);

      # document* documents
      # one or more documents to insert into the collection
      #
      for @documents -> $document {
        $B-OP-INSERT ~= self.encode-document($document);
      }

      # MsgHeader header
      # standard message header
      #
      my Buf $msg-header = self!enc-msg-header( $B-OP-INSERT.elems, C-OP-INSERT);

      # send message without waiting for response
      #
      $collection.database.client.send( $msg-header ~ $B-OP-INSERT, False);
    }
}}
#`{{
    #---------------------------------------------------------------------------
    #
    method OP_KILL_CURSORS ( *@cursors --> Nil ) is DEPRECATED('OP-KILL-CURSORS') {
      self.OP-KILL-CURSORS(@cursors);
    }
}}
#`{{
    method OP-KILL-CURSORS ( *@cursors --> Nil ) {
      # http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-OPKILLCURSORS

      my Buf $B-OP-KILL_CURSORS = [~]

        # int32 ZERO
        # 0 - reserved for future use
        #
        encode-int32(0),

        # int32 numberOfCursorIDs
        # number of cursorIDs in message
        #
        encode-int32(+@cursors);

      # int64* cursorIDs
      # sequence of cursorIDs to close
      #
      for @cursors -> $cursor {
        $B-OP-KILL_CURSORS ~= $cursor.id;
      }

      # MsgHeader header
      # standard message header
      #
      my Buf $msg-header = self!enc-msg-header(
        $B-OP-KILL_CURSORS.elems,
        BSON::C-OP-KILL-CURSORS
      );

      # send message without waiting for response
      #
      @cursors[0].collection.database.client.send( $msg-header ~ $B-OP-KILL_CURSORS, False);
    }
}}
#`{{
    #---------------------------------------------------------------------------
    #
    method OP_UPDATE (
      $collection, Int $flags, %selector, %update
      --> Nil
    ) is DEPRECATED('OP-UPDATE') {

      self.OP-UPDATE( $collection, $flags, %selector, %update);
    }

    method OP-UPDATE ( $collection, Int $flags, %selector, %update --> Nil ) {
      # http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-OPUPDATE

      my Buf $B-OP-UPDATE = [~]

        # int32 ZERO
        # 0 - reserved for future use
        #
        encode-int32(0),

        # cstring fullCollectionName
        # "dbname.collectionname"
        #
        encode-cstring($collection.full-collection-name),

        # int32 flags
        # bit vector
        #
        encode-int32($flags),

        # document selector
        # query object
        #
        self.encode-document(%selector),

        # document update
        # specification of the update to perform
        #
        self.encode-document(%update);

      # MsgHeader header
      # standard message header
      #
      my Buf $msg-header = self!enc-msg-header(
        $B-OP-UPDATE.elems, C-OP-UPDATE
      );

      # send message without waiting for response
      #
      $collection.database.client.send( $msg-header ~ $B-OP-UPDATE, False);
    }
}}
#`{{
    #---------------------------------------------------------------------------
    #
    method OP_DELETE (
      $collection, Int $flags, %selector
      --> Nil
    ) is DEPRECATED('OP-DELETE') {

      self.OP-DELETE( $collection, $flags, %selector);
    }

    method OP-DELETE ( $collection, Int $flags, %selector --> Nil ) {
      # http://www.mongodb.org/display/DOCS/Mongo+Wire+Protocol#MongoWireProtocol-OPDELETE

      my Buf $B-OP-DELETE = [~]

        # int32 ZERO
        # 0 - reserved for future use
        #
        encode-int32(0),

        # cstring fullCollectionName
        # "dbname.collectionname"
        #
        encode-cstring($collection.full-collection-name),

        # int32 flags
        # bit vector
        #
        encode-int32($flags),

        # document selector
        # query object
        #
        self.encode-document(%selector);

      # MsgHeader header
      # standard message header
      #
      my Buf $msg-header = self!enc-msg-header(
        $B-OP-DELETE.elems, C-OP-DELETE
      );

      # send message without waiting for response
      #
      $collection.database.client.send( $msg-header ~ $B-OP-DELETE, False);
    }
}}
