(*

Copyright (c) 2008 The Regents of the University of California
All rights reserved.

Authors: Luca de Alfaro, Ian Pye 

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. The names of the contributors may not be used to endorse or promote
products derived from this software without specific prior written
permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

 *)

open Json_type
open Json_type.Browse
open Online_types

(** This class provides a handle for accessing the database in the on-line 
    implementation.
    I don't know how it is created; most likely, it would take a database 
    name and password, or something like that, to connect to the db. *)
class db  
  (user : string)
  (auth : string)
  (database : string) =
        
  let dbh = Dbi_mysql.connect ~user:user ~password:auth database in
    
  object(self)
    
    (* HERE are all of the prepaired sql statments used below *)
    val mutable sth_select_page_text = dbh#prepare_cached "SELECT current_rev_text FROM 
          text_split_version WHERE page_id = ?"
    val sth_delet_text_split = dbh#prepare_cached "DELETE FROM text_split_version 
          WHERE page_id = ?" 
    val sth_insert_text_split = dbh#prepare_cached "INSERT INTO text_split_version 
          (current_rev_text, page_id) VALUES (?, ?)"    
    val sth_select_edit_list = dbh#prepare_cached "SELECT edit_type, val1,
          val2, val3 FROM edit_lists WHERE 
          from_revision = ? AND to_revision  = ?"
    val sth_ins_ins_edit_lists = dbh#prepare_cached "INSERT INTO edit_lists (from_revision,
          to_revision, edit_type, val1, val2 ) VALUES (?, ?, 'Ins', ?, ?) " 
    val sth_ins_mov_edit_lists = dbh#prepare_cached "INSERT INTO edit_lists (from_revision,
          to_revision, edit_type, val1, val2, val3 ) VALUES (?, ?, 'Mov', ?,
          ?, ?) " 
    val sth_ins_del_edit_lists = dbh#prepare_cached "INSERT INTO edit_lists (from_revision,
          to_revision, edit_type, val1, val2 ) VALUES (?, ?, 'Del', ?, ?) " 
    val sth_select_user_rep = dbh#prepare_cached "SELECT user_rep FROM trust_user_rep 
          WHERE user_id = ?" 
    val sth_update_user_rep = dbh#prepare_cached "UPDATE trust_user_rep SET user_rep = 
          ? WHERE user_id = ?" 
    val sth_insert_user_rep = dbh#prepare_cached "INSERT INTO trust_user_rep
          (user_id,  user_rep) VALUES (?, ?)" 
    val sth_delete_hist = dbh#prepare_cached "DELETE FROM user_rep_history WHERE 
          user_id = ? AND change_time = ?" 
    val sth_insert_hist = dbh#prepare_cached "INSERT INTO user_rep_history 
          (user_id, rep_before, rep_after, change_time) VALUES
          (?, ?, ?, ?)" 
    val sth_delete_markup = dbh#prepare_cached "DELETE FROM colored_markup WHERE 
          revision_id = ?" 
    val sth_insert_markup = dbh#prepare_cached "INSERT INTO colored_markup 
          (revision_id, revision_text) VALUES (?, ?) " 
    val sth_select_markup = dbh#prepare_cached "SELECT revision_text FROM 
          colored_markup WHERE revision_id = ?" 
    val sth_insert_chunk = dbh#prepare_cached "INSERT INTO dead_page_chunks (chunk_id,
          chunk_json) VALUES (?, ?)"
    val sth_select_chunk = dbh#prepare_cached "SELECT chunk_json FROM dead_page_chunks 
          WHERE chunk_id = ?"  
    val sth_delete_feedback = dbh#prepare_cached "DELETE FROM feedback WHERE revid1 
          = ? AND revid2 = ? AND userid1 = ? AND userid2 = ? AND timestamp = ?"
    val sth_insert_feedback = dbh#prepare_cached "INSERT INTO feedback (revid1, 
          userid1, revid2, userid2, timestamp, q) VALUES (?, ?, ?, ?, ?, ?)"  
    val sth_select_feedback = dbh#prepare_cached "SELECT revid2, userid2, timestamp, 
          q FROM feedback WHERE revid1 = ?"   

    (** [read_text_split_version page_id] given a [page_id] returns a 
	string associated with the page in the db.  The string 
	represents the version of Text.ml that has 
	been used to split a revision in words. *)
    method read_text_split_version (page_id : int) : string = 
      sth_select_page_text#execute [`Int page_id];
      sth_select_page_text#fetch1string () 

    (** [write_text_split_version page_id s] writes to the db 
	a string [s] associated with a page [page_id].  The string
	represents the version of Text.ml that has 
	been used to split a revision in words, and returns it. *)
    method write_text_split_version (page_id : int) (page_text : string) : unit =
    
      (* First we delete any pre-existing text. *)
      sth_delet_text_split#execute [`Int page_id ];
      (* Next we add in the new text. *)
      sth_insert_text_split#execute [`String page_text; `Int page_id ];
      dbh#commit ()

      
    (** [read_edit_diff revid1 revid2] reads from the database the edit list 
	from the (live) text of revision [revid1] to revision [revid2]. *)
    method read_edit_diff (revid1 : int) (revid2 : int) : (Editlist.edit list) =
      
      sth_select_edit_list#execute [`Int revid1; `Int revid2];
      let elist = [] in
      let p_elist = ref elist in
      let f row = (match row with
                | [ `String etype; `Int val1; `Int val2; `Null ] ->
                  ( match etype with
                    | "Ins" -> p_elist := Editlist.Ins (val1, val2) :: !p_elist
                    | "Del" -> p_elist := Editlist.Del (val1, val2) :: !p_elist
                    | _ -> assert false )
                | [ `String etype; `Int val1; `Int val2; `Int val3 ] ->
                  ( match etype with
                    | "Mov" -> p_elist := Editlist.Mov (val1, val2, val3) :: !p_elist
                    | _ -> assert false )
                | _ ->
                    assert false ) in
      sth_select_edit_list#iter f ;
      !p_elist
      
     
    (** [write_edit_diff revid1 revid2 elist] writes to the database the edit list 
	[elist] from the (live) text of revision [revid1] to revision [revid2]. *)
    method write_edit_diff (revid1 : int) (revid2 : int) (elist : Editlist.edit
    list) : unit = 
      let f ed =
        match ed with
          | Editlist.Ins (i, l) -> sth_ins_ins_edit_lists#execute [`Int revid1; 
                `Int revid2; `Int i; `Int l ];

          | Editlist.Del (i, l) -> sth_ins_del_edit_lists#execute [`Int revid1; 
                `Int revid2; `Int i; `Int l ];

          | Editlist.Mov (i, j, l) -> sth_ins_mov_edit_lists#execute [`Int revid1; 
                `Int revid2; `Int i; `Int j; `Int l ]; 
          in
      List.iter f elist
    

    (** [get_rep uid] gets the reputation of user [uid], from a table 
	      relating user ids to their reputation 
        @raise Not_found if no tuple is returned by the database.
    *)
    method get_rep (uid : int) : float =
      sth_select_user_rep#execute [`Int uid];
      let row = sth_select_user_rep#fetch1 () in
      match row with 
        | [ `Float rep] -> rep
        | _ -> assert false  

    (** [set_rep uid r] sets, in the table relating user ids to reputations, 
	  the reputation of user [uid] to be equal to [r]. *)
    method set_rep (uid : int) (rep : float) =
      (* first check to see if there exists the user already *)
      try
        ignore (self#get_rep uid ) ;
        sth_update_user_rep#execute [`Int uid; `Float rep ]; 
      with
        Not_found -> 
          sth_insert_user_rep#execute [`Int uid; `Float rep ];  
      dbh#commit()


    (** [set_rep_hist uid t r0 r1] writes, in a table with keys user_id, time, 
	and reputation, that at time [t] the reputation of user [uid] went from
	[r0] to [r1]. *)
    method set_rep_hist (uid : int) (timet : float) (r0 : float) (r1 : float)
    : unit =
      (* First we delete any pre-existing text. *)
      sth_delete_hist#execute [`Int uid; `Float timet ];

      (* Next we add in the new text. *)
      sth_insert_hist#execute [`Int uid; `Float r0; `Float r1; `Float timet ];
      dbh#commit ()


    (** [write_colored_markup rev_id markup] writes, in a table with columns by 
	(revision id, string), that the string [markup] is associated with the 
	revision with id [rev_id]. 
	The [markup] represents the main text of the revision, annotated with trust 
	and origin information; it is what the "colored revisions" of our 
	batch demo are. 
	When visitors want the "colored" version of a wiki page, it is this chunk 
	they want to see.  Therefore, it is very important that this chunk is 
	easy and efficient to read.  A filesystem implementation, for small wikis, 
	may be highly advisable. *)
    (* This is currently a first cut, which will be hopefully optimized later *)
    method write_colored_markup (rev_id : int) (markup : string) : unit =
      (* First we delete any pre-existing text. *)
      sth_delete_markup#execute [`Int rev_id ];
      (* Next we add in the new text. *)
      sth_insert_markup#execute [`Int rev_id; `String markup ];
      dbh#commit ()

    (** [read_colored_markup rev_id] reads the text markup of a revision with id
	[rev_id].  The markup is the text of the revision, annontated with trust
	and origin information. *)
    method read_colored_markup (rev_id : int) : string =
      sth_select_markup#execute [`Int rev_id];
      sth_select_markup#fetch1string ()


    (** [write_dead_page_chunks page_id chunk_list] writes, in a table indexed by 
	(page id, string list) that the page with id [page_id] is associated 
	with the "dead" strings of text [chunk1], [chunk2], ..., where
	[chunk_list = [chunk1, chunk2, ...] ]. 
	The chunk_list contains text that used to be present in the article, but has 
	been deleted; the database records its existence. *)
    method write_dead_page_chunks (page_id : int) (clist : Online_types.chunk_t
    list) : unit =
      
      let f (chk : Online_types.chunk_t) = (
        let text_lst = [] in
        let p_text_lst = ref text_lst in
        let trust_lst = [] in
        let p_trust_lst = ref trust_lst in
        let origin_lst = [] in
        let p_origin_lst = ref origin_lst in 
        for i = 0 to (Array.length chk.text) - 1 do 
          begin
            p_text_lst := String (Array.get chk.text i) :: !p_text_lst;
            p_trust_lst := Float (Array.get chk.trust i) :: !p_trust_lst;
            p_origin_lst := Int (Array.get chk.origin i) :: !p_origin_lst;
          end ;  
        done;
        let obj = Object [ "timestamp", Float (chk.timestamp) ;
                "n_del_revisions", Int (chk.n_del_revisions); 
                "text", Array (List.rev !p_text_lst);
                "trust", Array (List.rev !p_trust_lst);
                "origin", Array (List.rev !p_origin_lst)
                ] in
            let jsonstr = Json_io.string_of_json ~compact:true obj in 
            sth_insert_chunk#execute [`Int page_id; `String jsonstr ];
      ) in
      List.iter f clist;
      dbh#commit ()

    (** [read_dead_page_chunks page_id] returns the list of dead chunks associated
	with the page [page_id]. *)
    method read_dead_page_chunks (page_id : int) : Online_types.chunk_t list =
     
      let json2float (j_arr : Json_type.t array) (x : float) = (
        let txt = Array.make (Array.length j_arr) x in     
        for i = 0 to (Array.length j_arr) - 1 do
          txt.(i) <- (float j_arr.(i));
        done;
        txt 
      ) in
      let json2string (j_arr : Json_type.t array) (x : string) = (
        let txt = Array.make (Array.length j_arr) x in     
        for i = 0 to (Array.length j_arr) - 1 do
          txt.(i) <- (string j_arr.(i));
        done;
        txt
      ) in
      let json2int (j_arr : Json_type.t array) (x : int) = (
        let txt = Array.make (Array.length j_arr) x in     
        for i = 0 to (Array.length j_arr) - 1 do
          txt.(i) <- (int j_arr.(i));
        done;
        txt
      ) in

      let chunks = [] in
      let p_chunks = ref chunks in
      let f row = (match row with
        | [ `String json_str ] ->
            let json_obj = Json_io.json_of_string json_str in
            let tbl = make_table (objekt json_obj) in
            p_chunks := { timestamp = float (field tbl "timestamp");
                          n_del_revisions = int (field tbl "n_del_revisions");
                          text = json2string (Array.of_list (array (field 
                              tbl "text"))) "";
                          trust = json2float (Array.of_list (array (field 
                              tbl "trust"))) 0.0;
                          origin = json2int (Array.of_list (array (field 
                              tbl "origin"))) 0;
                        } :: !p_chunks
        | _ ->
            assert false ) in

      sth_select_chunk#execute [ `Int page_id ];
      sth_select_chunk#iter f;
      !p_chunks;


  (*  [write_feedback revid1 userid1, revid2, userid2, timestamp, q] adds
          one such tuple to the db. *)
    method write_feedback (revid1 :int) (userid1 : int) (revid2 : int) (userid2
        : int) (times : float) (q : float) : unit = 
      (* First we delete any pre-existing text. *)
      sth_delete_feedback#execute [`Int revid1; `Int revid2; `Int userid1; 
          `Int userid2; `Float times ];
      (* Next we add in the new text. *) 
      sth_insert_feedback#execute [`Int revid1; `Int userid1; `Int revid2; 
          `Int userid2; `Float times; `Float q];
      dbh#commit ()

    (** [read_feedback_by revid1] reads from the db all the (revid2,
      userid2,  timestamp, q) that 
      have been caused by the revision with id [revid1]. *)
    method read_feedback_by (revid1 : int) : (int * int * float * float) list = 
      let replist = [] in
      let p_replist = ref replist in
      let f row = (match row with
        | [ `Int r2; `Int u2; `Float t; `Float q] ->
            p_replist := (r2, u2, t, q) :: !p_replist
        | _ ->
            assert false ) in
      sth_select_feedback#execute [`Int revid1];
      sth_select_feedback#iter f;
      !p_replist;

    (** Clear everything out -- INTENDED FOR UNIT TESTING ONLY *)
    method delete_all (really : bool) =
      match really with
        | true -> (
            ignore (dbh#ex "DELETE FROM colored_markup" []);
            ignore (dbh#ex "DELETE FROM dead_page_chunks" []);
            ignore (dbh#ex "DELETE FROM edit_lists" []);
            ignore (dbh#ex "DELETE FROM feedback" []);
            ignore (dbh#ex "DELETE FROM text_split_version" []); 
            ignore (dbh#ex "DELETE FROM trust_user_rep" []);
            ignore (dbh#ex "DELETE FROM user_rep_history" []); 
            dbh#commit())
        | false -> dbh#commit()

  end;; (* online_db *)
