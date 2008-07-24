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


(* To do: 
   - Fix locking 
 *)

open Online_types
open Mysql
open Sexplib.Conv
open Sexplib.Sexp
open Sexplib
open Printf

TYPE_CONV_PATH "UCSC_WIKI_RESEARCH"

(* Returned whenever something is not found *)
exception DB_Not_Found

(* Timestamp in the DB *)
type timestamp_t = int * int * int * int * int * int

let debug_mode = true;;

(* This is the function that sexplib uses to convert floats *)
Sexplib.Conv.default_string_of_float := (fun n -> sprintf "%.4G" n);;

(* This is the function that sexplib uses to convert strings *)
Sexplib.Conv.default_string_of_string := (fun str -> sprintf "%s" str);;

(* Should a commit be issued after every insert? This is needed if there are multiple clients. *)
let commit_frequently = false;;

let rec format_string (str : string) (vals : string list) : string =                    
  match vals with                                                                       
    | [] -> if debug_mode then print_endline str; str
    | hd::tl -> (match (ExtString.String.replace str "?" hd) with                       
      | (true, newstr) -> format_string newstr tl                                       
      | (false, newstr) -> newstr)                                                      
;;


(** This class provides a handle for accessing the database in the on-line 
    implementation. *)

class db  
  (user : string)
  (auth : string)
  (database : string) =
 
  let db_param = {dbhost = None;
                  dbport = None;
                  dbname = Some database; 
                  dbpwd = Some auth;
                  dbuser = Some user} in
  let dbh = (Mysql.connect db_param) in
   
  object(self)
     
    (* HERE are all of the prepaired sql statments used below *)
    val sth_select_edit_list_flat = "SELECT version, edits FROM wikitrust_edit_lists WHERE from_revision = ? AND to_revision  = ?"
    val sth_insert_edit_list_flat = "INSERT INTO wikitrust_edit_lists (version, edits, from_revision, to_revision) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE version = ?, edits = ?"

    val sth_select_user_rep = "SELECT user_rep FROM wikitrust_user WHERE user_id = ?" 
    val sth_update_user_rep = "UPDATE wikitrust_user SET user_rep = ? WHERE user_id = ?" 
    val sth_insert_user_rep = "INSERT INTO wikitrust_user (user_id,  user_rep) VALUES (?, ?)" 

    val sth_delete_markup = "DELETE FROM wikitrust_colored_markup WHERE revision_id = ?"      
    val sth_insert_markup = "INSERT INTO wikitrust_colored_markup (revision_id, revision_text) VALUES (?, ?)" 
    val sth_select_markup = "SELECT revision_text FROM wikitrust_colored_markup WHERE revision_id = ?" 

    val sth_select_author_sigs = "SELECT sigs FROM wikitrust_sigs WHERE revision_id = ?"
    val sth_insert_author_sigs = "INSERT INTO wikitrust_sigs (revision_id, sigs) VALUES (?, ?)"
    val sth_delete_author_sigs = "DELETE FROM wikitrust_sigs WHERE revision_id = ?"

    val sth_select_dead_chunks = "SELECT deleted_chunks FROM wikitrust_page WHERE page_id = ?"
    val sth_delete_chunks = "DELETE FROM wikitrust_page WHERE page_id = ?"
    val sth_insert_dead_chunks = "INSERT INTO wikitrust_page (page_id, deleted_chunks) VALUES (?, ?)"

    val sth_select_revision_info = "SELECT quality_info FROM wikitrust_revision WHERE revision_id = ?"
    val sth_delete_revision_info = "DELETE FROM wikitrust_revision WHERE revision_id = ?"
    val sth_insert_revision_info = "INSERT INTO wikitrust_revision (revision_id, quality_info, reputation_delta) VALUES (?, ?, ?, ?)"

    val sth_select_revs = "SELECT rev_id, rev_page, rev_text_id, rev_timestamp, rev_user, rev_user_text, rev_minor_edit, rev_comment FROM revision WHERE rev_page = ? AND rev_timestamp <= ? ORDER BY rev_timestamp DESC"
    val sth_select_rev_timestamp = "SELECT rev_timestamp FROM revision WHERE rev_id = ?"
    val sth_select_all_revs = "SELECT rev_id, rev_page, rev_text_id, rev_timestamp, rev_user, rev_user_text, rev_minor_edit, rev_comment FROM revision ORDER BY rev_timestamp ASC"
    val sth_select_all_revs_after = "SELECT rev_id, rev_page, rev_text_id, rev_timestamp, rev_user, rev_user_text, rev_minor_edit, rev_comment FROM revision WHERE rev_timestamp > ? ORDER BY rev_timestamp ASC"      

    val sth_select_text = "SELECT old_text FROM text WHERE old_id = ?"
    val sth_select_last_colored_rev = "SELECT A.revision_id, B.rev_page, A.coloredon FROM wikitrust_colored_markup AS A JOIN revision AS B ON (A.revision_id = B.rev_id) ORDER BY coloredon DESC LIMIT 1"

    val sth_update_histogram = "UPDATE wikitrust_global SET median = ?, rep_0 = ?, rep_1 = ?, rep_2 = ?, rep_3 = ?, rep_4 = ?, rep_5 = ?, rep_6 = ?, rep_7 = ?, rep_8 = ?, rep_9 =?"
    val sth_select_histogram = "SELECT * FROM wikitrust_global"
      
    (* Commits any changes to the db *)
    method commit : bool =
      ignore (Mysql.exec dbh "COMMIT");
      match Mysql.status dbh with
        | StatusError err -> false
        | _ -> true
	    
    (** [get_histogram] Returns a histogram showing the number of users 
	at each reputation level, and the median. *)
    method get_histogram : float array * float =
      match fetch (Mysql.exec dbh sth_select_histogram) with
        | None -> raise DB_Not_Found
        | Some row -> ([| not_null float2ml row.(1); not_null float2ml row.(2); not_null float2ml row.(3); 
			  not_null float2ml row.(4);  not_null float2ml row.(5);
			  not_null float2ml row.(6);  not_null float2ml row.(7);
			  not_null float2ml row.(8);  not_null float2ml row.(9); not_null float2ml row.(10);
		       |], not_null float2ml row.(0))
    
    (** [set_histogram hist hival] writes to the db that the histogram is [hist], and the 
	chosen median is [hival].  *)
    method set_histogram (hist : float array) (hival: float) : unit = 
      let sql = format_string sth_update_histogram 
		   ((ml2float hival) :: Array.to_list (Array.map ml2float hist)) in
	ignore (Mysql.exec dbh sql);
	if commit_frequently then ignore (Mysql.exec dbh "COMMIT")      

    (** Returns the last colored revision, if any *)
    method fetch_last_colored_rev : (int * int * timestamp_t) = 
      match fetch (Mysql.exec dbh sth_select_last_colored_rev) with
        | None -> raise DB_Not_Found
        | Some row -> (not_null int2ml row.(0), not_null int2ml row.(1), 
            not_null timestamp2ml row.(2))
  
    (** [sth_select_all_revs_after (int * int * int * int * int * int)] returns all 
        revs created after the given timestamp. *)
    method fetch_all_revs_after (timestamp : timestamp_t) : Mysql.result =   
      Mysql.exec dbh (format_string sth_select_all_revs_after [ml2timestamp timestamp])

    (** [fetch_all_revs] returns a cursor that points to all revisions in the database, 
	in ascending order of timestamp. *)
    method fetch_all_revs : Mysql.result = 
      Mysql.exec dbh (format_string sth_select_all_revs [])
  
    (** [fetch_revs page_id timestamp] returns a cursor that points to all 
	revisions of page [page_id] with time prior or equal to [timestamp]. *)
    method fetch_revs (page_id : int) (timestamp: timestamp_t) : Mysql.result =
      Mysql.exec dbh (format_string sth_select_revs [ml2int page_id; ml2timestamp timestamp])


   (** [fetch_rev_timestamp rev_id] returns the timestamp of revision [rev_id] *)
    method fetch_rev_timestamp (rev_id: int) : timestamp_t = 
      let result = Mysql.exec dbh (format_string sth_select_rev_timestamp [ml2int rev_id]) in 
      match fetch result with 
	None -> raise DB_Not_Found
      | Some row -> not_null timestamp2ml row.(0)


    (** [read_revision_info rev_id] reads the wikitrust information of revision_id *)
    method read_revision_info (rev_id: int) : qual_info_t = 
      let result = Mysql.exec dbh (format_string sth_select_revision_info [ml2int rev_id]) in
      match fetch result with
        | None -> raise DB_Not_Found
        | Some x -> of_string__of__of_sexp qual_info_t_of_sexp (not_null str2ml x.(0))

    (** [write_revision_info rev_id quality_info elist] writes the wikitrust data 
	associated with revision with id [rev_id] *)
    method write_revision_info (rev_id: int) (quality_info: qual_info_t) : unit = 
      let rep_delta = quality_info.reputation_gain in 
      ignore (Mysql.exec dbh (format_string sth_delete_revision_info [ml2int rev_id]));
      ignore (Mysql.exec dbh (format_string sth_insert_revision_info [
	ml2int rev_id;
	ml2str (string_of__of__sexp_of sexp_of_qual_info_t quality_info); 
	ml2float rep_delta;
      ]))


    (** [get_rev_text text_id] returns the text associated with text id [text_id] *)
    method read_rev_text (text_id: int) : string = 
      let result = Mysql.exec dbh (format_string sth_select_text [ml2int text_id]) in 
      match Mysql.fetch result with 
        | None -> raise DB_Not_Found
        | Some y -> not_null str2ml y.(0)


    (** [get_rep uid] gets the reputation of user [uid], from a table 
	      relating user ids to their reputation 
        @raise DB_Not_Found if no tuple is returned by the database.
    *)
    method get_rep (uid : int) : float =
      let result = Mysql.exec dbh (format_string sth_select_user_rep [ml2int uid]) in
      match Mysql.fetch result with 
        | None -> raise DB_Not_Found
        | Some x -> not_null float2ml x.(0)
      

    (** [set_rep uid r] sets, in the table relating user ids to reputations, 
	  the reputation of user [uid] to be equal to [r]. *)
    method set_rep (uid : int) (rep : float) =
      (* first check to see if there exists the user already *)
      try
        ignore (self#get_rep uid ) ;
        ignore (Mysql.exec dbh (format_string sth_update_user_rep 
            [ml2float rep; ml2int uid ])); 
      with
        DB_Not_Found -> 
          ignore (Mysql.exec dbh (format_string sth_insert_user_rep 
              [ml2int uid; ml2float rep ]));  
      if commit_frequently then ignore (Mysql.exec dbh "COMMIT")
  
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
      ignore (Mysql.exec dbh (format_string sth_delete_markup
          [ml2int rev_id ]));
      ignore (Mysql.exec dbh (format_string sth_insert_markup 
          [ml2int rev_id; ml2str markup ]));
      if commit_frequently then ignore (Mysql.exec dbh "COMMIT")

    (** [read_colored_markup rev_id] reads the text markup of a revision with id
	[rev_id].  The markup is the text of the revision, annontated with trust
	and origin information. *)
    method read_colored_markup (rev_id : int) : string =
      let result = Mysql.exec dbh (format_string sth_select_markup 
          [ml2int rev_id]) in
      match Mysql.fetch result with
        | None -> raise DB_Not_Found
        | Some x -> not_null str2ml x.(0)

    (** [write_author_sigs rev_id sigs] writes that the author signatures 
	for the revision [rev_id] are [sigs]. *)
    method write_author_sigs (rev_id: int) 
      (sigs: Author_sig.packed_author_signature_t array) : unit = 
      let g = sexp_of_array Author_sig.sexp_of_sigs in 
      let s = string_of__of__sexp_of g sigs in 
      ignore (Mysql.exec dbh (format_string sth_delete_author_sigs 
	[ml2int rev_id])); 
      ignore (Mysql.exec dbh (format_string sth_insert_author_sigs
	[ml2int rev_id; ml2str s])) 

  
    (** [read_author_sigs rev_id] reads the author signatures for the revision 
	[rev_id]. 
	TODO: Note that we can keep the signatures separate from the text 
	because it is not a bit deal if we occasionally mis-align text and 
	signatures when we change the parsing algorithm: all that can happen 
	is that occasinally an author can give trust twice to the same piece of text. 
	However, it is imperative that in the calling code we check that the list
	of signatures has the same length as the list of words. 
        *)
    method read_author_sigs 
      (rev_id: int) : Author_sig.packed_author_signature_t array = 
      let result = Mysql.exec dbh (format_string sth_select_author_sigs 
          [ml2int rev_id ]) in 
      match Mysql.fetch result with 
	None -> raise DB_Not_Found
      | Some x -> begin
	  let g sx = array_of_sexp Author_sig.sigs_of_sexp sx in 
	  of_string__of__of_sexp g (not_null str2ml x.(0))
	end

   (** [delete_author_sigs rev_id] removes from the db the author signatures for [rev_id]. *)
    method delete_author_sigs (rev_id: int) : unit = 
      ignore (Mysql.exec dbh (format_string sth_delete_author_sigs [ml2int rev_id]))

    (** [write_page_info page_id chunk_list] writes, in a table indexed by 
	(page id, string list) that the page with id [page_id] is associated 
	with the "dead" strings of text [chunk1], [chunk2], ..., where
	[chunk_list = [chunk1, chunk2, ...] ]. 
	The chunk_list contains text that used to be present in the article, but has 
	been deleted; the database records its existence. *)
    method write_page_info (page_id : int) (c_list : Online_types.chunk_t list) : unit = 
      let chunks_string = ml2str (string_of__of__sexp_of 
          (sexp_of_list sexp_of_chunk_t) c_list) in 
      ignore (Mysql.exec dbh (format_string sth_delete_chunks
        [ml2int page_id]));
      ignore (Mysql.exec dbh (format_string sth_insert_dead_chunks 
	[ml2int page_id; chunks_string ])); 
      if commit_frequently then ignore (Mysql.exec dbh "COMMIT")

    (** [read_page_info page_id] returns the list of dead chunks associated
	with the page [page_id]. *)
    method read_page_info (page_id : int) : Online_types.chunk_t list =
      let result = Mysql.exec dbh (format_string sth_select_dead_chunks
          [ml2int page_id ]) in 
      match Mysql.fetch result with 
	None -> raise DB_Not_Found
      | Some x -> of_string__of__of_sexp (list_of_sexp chunk_t_of_sexp) 
                      (not_null str2ml x.(0))

    (** [get_page_lock page_id] gets a lock for page [page_id], to guarantee 
	mutual exclusion on the updates for page [page_id]. *)
    method get_page_lock (page_id: int) = ()

    (** [release_page_lock page_id] releases the lock for page [page_id], to guarantee 
	mutual exclusion on the updates for page [page_id]. *)
    method release_page_lock (page_id: int) = ()

    (** [get_rep_lock] gets a lock for the global table of user reputations, to guarantee 
	serializability of the updates. *)
    method get_rep_lock = ()

    (** [release_rep_lock] releases a lock for the global table of user reputations, to guarantee 
	serializability of the updates. *)
    method release_rep_lock = ()

    (** Clear everything out *)
    method delete_all (really : bool) =
      match really with
        | true -> (
	    ignore (Mysql.exec dbh "DELETE FROM wikitrust_global");
	    ignore (Mysql.exec dbh "INSERT INTO wikitrust_global VALUES (0,0,0,0,0,0,0,0,0,0,0)");
            ignore (Mysql.exec dbh "TRUNCATE TABLE wikitrust_page" );
            ignore (Mysql.exec dbh "TRUNCATE TABLE wikitrust_revision" );
            ignore (Mysql.exec dbh "TRUNCATE TABLE wikitrust_colored_markup" );
            ignore (Mysql.exec dbh "TRUNCATE TABLE wikitrust_sigs" );
            ignore (Mysql.exec dbh "TRUNCATE TABLE wikitrust_user" ); 
            ignore (Mysql.exec dbh "COMMIT"))
        | false -> ignore (Mysql.exec dbh "COMMIT")

  end;; (* online_db *)

