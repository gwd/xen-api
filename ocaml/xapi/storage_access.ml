(*
 * Copyright (C) 2006-2011 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Threadext
open Stringext
module XenAPI = Client.Client
open Storage_interface

module D=Debug.Debugger(struct let name="storage_access" end)
open D

module Builtin_impl = struct
	(** xapi's builtin ability to call local SM plugins using the existing
	    protocol. The code here should only call the SM functions and encapsulate
	    the return or error properly. It should not perform side-effects on
	    the xapi database: these should be handled in the layer above so they
	    can be shared with other SM implementation types.

	    Where this layer has to perform interface adjustments (see VDI.activate
	    and the read/write debacle), this highlights desirable improvements to
	    the backend interface.
	*)

	type context = Smint.request

    let query context () = {
        name = "SMAPIv1 adapter";
        vendor = "XCP";
        version = "0.1";
        features = [];
    }

	module DP = struct
		let create context ~task ~id = assert false
		let destroy context ~task ~dp = assert false
		let diagnostics context () = assert false
	end

	module SR = struct
		let attach context ~task ~sr ~device_config =
			Server_helpers.exec_with_new_task "SR.attach" ~subtask_of:(Ref.of_string task)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					(* Existing backends expect an SRMaster flag to be added
					   through the device-config. *)
					let srmaster = Helpers.i_am_srmaster ~__context ~sr in
					let device_config = (Sm.sm_master srmaster) :: device_config in
					Sm.call_sm_functions ~__context ~sR:sr
						(fun _ _type ->
							try
								Sm.sr_attach (Some (Context.get_task_id __context), device_config) _type sr;
								Success Unit
							with e ->
								let e' = ExnHelper.string_of_exn e in
								error "SR.attach failed SR:%s error:%s" (Ref.string_of sr) e';
								Failure (Internal_error e')
						)
				)
		let detach context ~task ~sr =
			Server_helpers.exec_with_new_task "SR.detach" ~subtask_of:(Ref.of_string task)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_detach device_config _type sr;
								Success Unit
							with e ->
								let e' = ExnHelper.string_of_exn e in
								error "SR.detach failed SR:%s error:%s" (Ref.string_of sr) e';
								Failure (Storage_interface.Internal_error e')
						)
				)

		let reset context ~task ~sr = assert false

		let destroy context ~task ~sr = 
			Server_helpers.exec_with_new_task "SR.destroy" ~subtask_of:(Ref.of_string task)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_delete device_config _type sr;
								Success Unit
							with
								| Smint.Not_implemented_in_backend ->
									Failure (Storage_interface.Backend_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr ]))
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.detach failed SR:%s error:%s" (Ref.string_of sr) e';
									Failure (Storage_interface.Internal_error e')
						)
				)

		let scan context ~task ~sr =
			Server_helpers.exec_with_new_task "SR.scan" ~subtask_of:(Ref.of_string task)
				(fun __context ->
					let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in

					Sm.call_sm_functions ~__context ~sR:sr
						(fun device_config _type ->
							try
								Sm.sr_scan device_config _type sr;
								let open Db_filter_types in
								let vdis = Db.VDI.get_records_where ~__context ~expr:(Eq(Field "SR", Literal (Ref.string_of sr))) in
								let info_of_vdi (vdi_ref, vdi_rec) = {
									vdi = vdi_rec.API.vDI_location;
									name_label = vdi_rec.API.vDI_name_label;
									name_description = vdi_rec.API.vDI_name_description;
									ty = Record_util.vdi_type_to_string vdi_rec.API.vDI_type;
									metadata_of_pool = Ref.string_of vdi_rec.API.vDI_metadata_of_pool;
									is_a_snapshot = vdi_rec.API.vDI_is_a_snapshot;
									snapshot_time = Date.to_string vdi_rec.API.vDI_snapshot_time;
									snapshot_of = Ref.string_of vdi_rec.API.vDI_snapshot_of;
									read_only = vdi_rec.API.vDI_read_only;
									virtual_size = vdi_rec.API.vDI_virtual_size;
									physical_utilisation = vdi_rec.API.vDI_physical_utilisation;
								} in
								Success (Vdis (List.map info_of_vdi vdis))
							with
								| Smint.Not_implemented_in_backend ->
									Failure (Storage_interface.Backend_error(Api_errors.sr_operation_not_supported, [ Ref.string_of sr ]))
								| e ->
									let e' = ExnHelper.string_of_exn e in
									error "SR.scan failed SR:%s error:%s" (Ref.string_of sr) e';
									Failure (Storage_interface.Internal_error e')
						)
				)			

		let list context ~task = assert false

	end

	module VDI = struct
		exception No_VDI

		let for_vdi ~task ~sr ~vdi op_name f =
			Server_helpers.exec_with_new_task op_name ~subtask_of:(Ref.of_string task)
				(fun __context ->
					let open Db_filter_types in
					match Db.VDI.get_records_where ~__context ~expr:(Eq (Field "location", Literal vdi)) with
						| (self, _) :: _ ->
							Sm.call_sm_vdi_functions ~__context ~vdi:self
								(fun device_config _type sr ->
									f device_config _type sr self
								)
						| [] -> raise No_VDI
				)
		(* Allow us to remember whether a VDI is attached read/only or read/write.
		   If this is meaningful to the backend then this should be recorded there! *)
		let vdi_read_write = Hashtbl.create 10
		let vdi_read_write_m = Mutex.create ()


		let attach context ~task ~dp ~sr ~vdi ~read_write =
			try
				let params =
					for_vdi ~task ~sr ~vdi "VDI.attach"
						(fun device_config _type sr self ->
							Sm.vdi_attach device_config _type sr self read_write
						) in
				Mutex.execute vdi_read_write_m
					(fun () -> Hashtbl.replace vdi_read_write (sr, vdi) read_write);
				Success (Params params)
			with Api_errors.Server_error(code, params) ->
				Failure (Backend_error(code, params))

		let activate context ~task ~dp ~sr ~vdi =
			try
				let read_write = Mutex.execute vdi_read_write_m
					(fun () -> 
						if not (Hashtbl.mem vdi_read_write (sr, vdi)) then error "VDI.activate: doesn't know if sr:%s vdi:%s is RO or RW" sr vdi;
						Hashtbl.find vdi_read_write (sr, vdi)) in
				for_vdi ~task ~sr ~vdi "VDI.activate"
					(fun device_config _type sr self ->
						(* If the backend doesn't advertise the capability then do nothing *)
						if List.mem Smint.Vdi_activate (Sm.capabilities_of_driver _type)
						then Sm.vdi_activate device_config _type sr self read_write
						else info "%s sr:%s does not support vdi_activate: doing nothing" dp (Ref.string_of sr)
					);
				Success Unit
			with Api_errors.Server_error(code, params) ->
				Failure (Backend_error(code, params))

		let deactivate context ~task ~dp ~sr ~vdi =
			try
				for_vdi ~task ~sr ~vdi "VDI.deactivate"
					(fun device_config _type sr self ->
						(* If the backend doesn't advertise the capability then do nothing *)
						if List.mem Smint.Vdi_activate (Sm.capabilities_of_driver _type)
						then Sm.vdi_deactivate device_config _type sr self
						else info "%s sr:%s does not support vdi_activate: doing nothing" dp (Ref.string_of sr)
					);
				Success Unit
			with Api_errors.Server_error(code, params) ->
				Failure (Backend_error(code, params))

		let detach context ~task ~dp ~sr ~vdi =
			try
				for_vdi ~task ~sr ~vdi "VDI.detach"
					(fun device_config _type sr self ->
						Sm.vdi_detach device_config _type sr self
					);
				Mutex.execute vdi_read_write_m
					(fun () -> Hashtbl.remove vdi_read_write (sr, vdi));
				Success Unit
			with Api_errors.Server_error(code, params) ->
				Failure (Backend_error(code, params))

		let stat context ~task ~sr ~vdi () = assert false

        let require_uuid vdi_info =
            match vdi_info.Smint.vdi_info_uuid with
                | Some uuid -> uuid
                | None -> failwith "SM backend failed to return <uuid> field"

        let newvdi ~__context vi =
            (* The current backends stash data directly in the db *)
            let uuid = require_uuid vi in
            let ref = Db.VDI.get_by_uuid ~__context ~uuid in

            let r = Db.VDI.get_record ~__context ~self:ref in
            Vdi {
                vdi = r.API.vDI_location;
                name_label = r.API.vDI_name_label;
                name_description = r.API.vDI_name_description;
                ty = Record_util.vdi_type_to_string r.API.vDI_type;
				metadata_of_pool = Ref.string_of r.API.vDI_metadata_of_pool;
                is_a_snapshot = r.API.vDI_is_a_snapshot;
                snapshot_time = Date.to_string r.API.vDI_snapshot_time;
                snapshot_of = Ref.string_of r.API.vDI_snapshot_of;
                read_only = r.API.vDI_read_only;
                virtual_size = r.API.vDI_virtual_size;
                physical_utilisation = r.API.vDI_physical_utilisation;
            }

        let create context ~task ~sr ~vdi_info ~params =
            try
                Server_helpers.exec_with_new_task "VDI.create" ~subtask_of:(Ref.of_string task)
                    (fun __context ->
                        let sr = Db.SR.get_by_uuid ~__context ~uuid:sr in
                        let vi =
                            Sm.call_sm_functions ~__context ~sR:sr
                                (fun device_config _type ->
                                    Sm.vdi_create device_config _type sr params vdi_info.ty
                                        vdi_info.virtual_size vdi_info.name_label vdi_info.name_description
										vdi_info.metadata_of_pool vdi_info.is_a_snapshot
										vdi_info.snapshot_time vdi_info.snapshot_of vdi_info.read_only
                                ) in
                        Success (newvdi ~__context vi)
                    )
            with Api_errors.Server_error(code, params) ->
                Failure (Backend_error(code, params))

        let destroy context ~task ~sr ~vdi =
            try
                for_vdi ~task ~sr ~vdi "VDI.destroy"
                    (fun device_config _type sr self ->
                        Sm.vdi_delete device_config _type sr self
                    );
                Mutex.execute vdi_read_write_m
                    (fun () -> Hashtbl.remove vdi_read_write (sr, vdi));
                Success Unit
            with 
				| Api_errors.Server_error(code, params) ->
					Failure (Backend_error(code, params))
				| No_VDI ->
					Failure Vdi_does_not_exist
	end
end

module Qemu_blkfront = struct
	(** If the qemu is in a different domain to the storage backend, a blkfront is
		needed to exposes disks to guests so the emulated interfaces work. *)

	let get_qemu_vm ~__context ~vm = Helpers.get_domain_zero ~__context

	let needed ~__context ~self hvm =
		not(Db.VBD.get_empty ~__context ~self) && begin
            let userdevice = Db.VBD.get_userdevice ~__context ~self in
            let device_number = Device_number.of_string hvm userdevice in
            match Device_number.spec device_number with
                | Device_number.Ide(n, _) when n < 4 -> true
                | _ -> false
		end

	(* If we have a shared VDI (eg CDROM) we don't share the blkfront
	   to simplify the accounting. We use the other_config:related_to key
	   to distinguish the different VBDs. *)
	let vbd_opt ~__context ~self =
		let vdi = Db.VBD.get_VDI ~__context ~self in
		let user_vm = Db.VBD.get_VM ~__context ~self in
		let vm = get_qemu_vm ~__context ~vm:user_vm in
		if Db.is_valid_ref __context vdi
		then begin
			match List.filter (fun other ->
				try
					let vbd_r = Db.VBD.get_record ~__context ~self:other in
					true
					&& vbd_r.API.vBD_VM = vm
							&& (List.mem_assoc Xapi_globs.related_to_key vbd_r.API.vBD_other_config)
							&& (List.assoc Xapi_globs.related_to_key vbd_r.API.vBD_other_config = Ref.string_of self)
				with _ -> false (* the VBD may be destroyed concurrently *)
			) (Db.VDI.get_VBDs ~__context ~self:vdi) with
				| vbd :: _ -> Some vbd
				| [] -> None
		end else None

	let create ~__context ~self ~read_write hvm =
		match vbd_opt ~__context ~self with
			| Some vbd ->
				if not (Db.VBD.get_currently_attached ~__context ~self:vbd)
				then Helpers.call_api_functions ~__context
					(fun rpc session_id -> XenAPI.VBD.plug rpc session_id vbd)
			| None ->
				let vdi = Db.VBD.get_VDI ~__context ~self in
				let user_vm = Db.VBD.get_VM ~__context ~self in
				let vm = get_qemu_vm ~__context ~vm:user_vm in
				if needed ~__context ~self hvm
				then Helpers.call_api_functions ~__context
					(fun rpc session_id ->
						let mode = if read_write then `RW else `RO in
						let vbd = XenAPI.VBD.create
							~rpc ~session_id ~vM:vm ~vDI:vdi
							~other_config:[ Xapi_globs.related_to_key, Ref.string_of self ]
							~userdevice:"autodetect" ~bootable:false ~mode
							~_type:`Disk ~empty:false ~unpluggable:true
							~qos_algorithm_type:"" ~qos_algorithm_params:[] in
						XenAPI.VBD.plug rpc session_id vbd
					)

	let path_opt ~__context ~self =
		let vbd = vbd_opt ~__context ~self in
		let path_of vbd = "/dev/" ^ (Db.VBD.get_device ~__context ~self:vbd) in
		Opt.map path_of vbd

	let on_vbd ~__context ~self f =
		let vbd = vbd_opt ~__context ~self in
		Opt.iter
            (fun vbd ->
                Helpers.call_api_functions ~__context
                    (fun rpc session_id -> f rpc session_id vbd)
            ) vbd

	let unplug_nowait ~__context ~self =
		on_vbd ~__context ~self
			(fun rpc session_id vbd ->
				try XenAPI.VBD.unplug rpc session_id vbd
				with _ -> ()
			)
		
	let destroy ~__context ~self =
		on_vbd ~__context ~self
			(fun rpc session_id vbd ->
                Attach_helpers.safe_unplug rpc session_id vbd;
                XenAPI.VBD.destroy rpc session_id vbd
            )
end

module type SERVER = sig
    val process : Smint.request -> Rpc.call -> Rpc.response
end

let make_local _ =
    (module Server(Builtin_impl) : SERVER)

let make_remote host path =
	let open Xmlrpc_client in
    (module Server(Storage_proxy.Proxy(struct let rpc call = XMLRPC_protocol.rpc ~transport:(TCP(host, 8080)) ~http:(xmlrpc ~version:"1.0" path) call end)) : SERVER)

let bind ~__context ~pbd =
    (* Start the VM if necessary, record its uuid *)
    let driver = System_domains.storage_driver_domain_of_pbd ~__context ~pbd in
	System_domains.record_pbd_storage_driver_domain ~__context ~pbd ~domain:driver;
    if Db.VM.get_power_state ~__context ~self:driver = `Halted then begin
        info "PBD %s driver domain %s is offline: starting" (Ref.string_of pbd) (Ref.string_of driver);
        Helpers.call_api_functions ~__context
            (fun rpc session_id -> XenAPI.VM.start rpc session_id driver false false);
    end;
	let uuid = Db.VM.get_uuid ~__context ~self:driver in
    let ip_of driver =
        (* Find the VIF on the Host internal management network *)
        let vifs = Db.VM.get_VIFs ~__context ~self:driver in
        let hin = Helpers.get_host_internal_management_network ~__context in
        let ip =
            let vif =
                try
                    List.find (fun vif -> Db.VIF.get_network ~__context ~self:vif = hin) vifs
                with Not_found -> failwith (Printf.sprintf "PBD %s driver domain %s has no VIF on host internal management network" (Ref.string_of pbd) (Ref.string_of driver)) in
            match Xapi_udhcpd.get_ip ~__context vif with
                | Some (a, b, c, d) -> Printf.sprintf "%d.%d.%d.%d" a b c d
                | None -> failwith (Printf.sprintf "PBD %s driver domain %s has no IP on the host internal management network" (Ref.string_of pbd) (Ref.string_of driver)) in

        info "PBD %s driver domain uuid:%s ip:%s" (Ref.string_of pbd) uuid ip;
        if not(System_domains.wait_for (System_domains.pingable ip))
        then failwith (Printf.sprintf "PBD %s driver domain %s is not responding to IP ping" (Ref.string_of pbd) (Ref.string_of driver));
        if not(System_domains.wait_for (System_domains.queryable ip 8080))
        then failwith (Printf.sprintf "PBD %s driver domain %s is not responding to XMLRPC query" (Ref.string_of pbd) (Ref.string_of driver));
        ip in
    let sr = Db.PBD.get_SR ~__context ~self:pbd in
    let path = Xapi_services.path [ Xapi_services._services; Xapi_services._SM; Db.SR.get_type ~__context ~self:sr ] in

    let dom0 = Helpers.get_domain_zero ~__context in
    let module Impl = (val (if driver = dom0 then make_local path else make_remote (ip_of driver) path): SERVER) in
    let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
    info "SR %s will be implemented by %s in VM %s" sr path (Ref.string_of driver);
    Storage_mux.register sr (Impl.process (Some path)) uuid

let unbind ~__context ~pbd =
        let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
        Storage_mux.unregister sr

let rpc call = Storage_mux.Server.process None call

module Client = Client(struct let rpc = rpc end)

let start () =
	let open Storage_impl.Local_domain_socket in
	start Xapi_globs.storage_unix_domain_socket Storage_mux.Server.process


(** [datapath_of_vbd domid userdevice] returns the name of the datapath which corresponds
    to device [userdevice] on domain [domid] *)
let datapath_of_vbd ~domid ~userdevice =
	Printf.sprintf "vbd/%d/%s" domid userdevice

let unexpected_result expected x = match x with
	| Success _ ->
		failwith (Printf.sprintf "Run-time type error. Expected %s; got: %s" expected (string_of_result x))
	| Failure Sr_not_attached ->
		failwith "Storage_access failed with Sr_not_attached"
	| Failure Vdi_does_not_exist ->
		failwith "Storage_access failed with Vdi_does_not_exist"
	| Failure (Backend_error(code, params)) ->
		raise (Api_errors.Server_error(code, params))
	| Failure (Internal_error x) ->
		failwith (Printf.sprintf "Storage_access failed with: %s" x)
	| Failure Illegal_transition(a, b) ->
		failwith (Printf.sprintf "Storage_access failed with %s" (string_of_result x))

let expect_vdi f x = match x with
	| Success (Vdi v) -> f v
	| _ -> unexpected_result "Vdi _" x

let expect_params f x = match x with
	| Success (Params v) -> f v
	| _ -> unexpected_result "Params _" x

let expect_unit f x = match x with
	| Success Unit -> f ()
	| _ -> unexpected_result "()" x

let expect_string f x = match x with
	| Success (String x) -> f x
	| _ -> unexpected_result "String" x

let of_vbd ~__context ~vbd ~domid =
	let vdi = Db.VBD.get_VDI ~__context ~self:vbd in
	let location = Db.VDI.get_location ~__context ~self:vdi in
	let sr = Db.VDI.get_SR ~__context ~self:vdi in
	let userdevice = Db.VBD.get_userdevice ~__context ~self:vbd in
	let task = Context.get_task_id __context in
	let dp = datapath_of_vbd ~domid ~userdevice in
	rpc, (Ref.string_of task), dp, (Db.SR.get_uuid ~__context ~self:sr), location

(** [is_attached __context vbd] returns true if the [vbd] has an attached
    or activated datapath. *)
let is_attached ~__context ~vbd ~domid  =
	let rpc, task, dp, sr, vdi = of_vbd ~__context ~vbd ~domid in
	let open Vdi_automaton in
	let module C = Storage_interface.Client(struct let rpc = rpc end) in
	match C.VDI.stat ~task ~sr ~vdi () with
		| Success (Stat { superstate = Detached }) -> false
		| Success _ -> true
		| Failure _ as r -> error "Unable to query state of VDI: %s, %s" vdi (string_of_result r); false

(** [on_vdi __context vbd domid f] calls [f rpc dp sr vdi] which is
    useful for executing Storage_interface.Client.VDI functions  *)
let on_vdi ~__context ~vbd ~domid f =
	let rpc, task, dp, sr, vdi = of_vbd ~__context ~vbd ~domid in
	let module C = Storage_interface.Client(struct let rpc = rpc end) in
	let dp = C.DP.create task dp in
	f rpc task dp sr vdi

let reset ~__context ~vm =
	let task = Context.get_task_id __context in
	Opt.iter
		(fun pbd ->
			let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self:pbd) in
			info "Resetting all state associated with SR: %s" sr;
			expect_unit (fun () -> ())
				(Client.SR.reset (Ref.string_of task) sr);
			Db.PBD.set_currently_attached ~__context ~self:pbd ~value:false;
		) (System_domains.pbd_of_vm ~__context ~vm)

(** [attach_and_activate __context vbd domid f] calls [f params] where
    [params] is the result of attaching a VDI which is also activated.
    This should be used everywhere except the migrate code, where we want fine-grained
    control of the ordering of attach/activate/deactivate/detach *)
let attach_and_activate ~__context ~vbd ~domid ~hvm f =
	let read_write = Db.VBD.get_mode ~__context ~self:vbd = `RW in
	let result = on_vdi ~__context ~vbd ~domid
		(fun rpc task dp sr vdi ->
			let module C = Storage_interface.Client(struct let rpc = rpc end) in
			expect_params
				(fun path ->
					expect_unit
						(fun () ->
							f path
						) (C.VDI.activate task dp sr vdi)
				) (C.VDI.attach task dp sr vdi read_write)
		) in
	Qemu_blkfront.create ~__context ~self:vbd ~read_write hvm;
	result

(** [deactivate_and_detach __context vbd domid] idempotent function which ensures
    that any attached or activated VDI gets properly deactivated and detached. *)
let deactivate_and_detach ~__context ~vbd ~domid ~unplug_frontends =
	(* Remove the qemu frontend first: this will not pass the deactivate/detach
	   through to the backend so an SM backend failure won't cause us to leak
	   a VBD. *)
	if unplug_frontends
	then Qemu_blkfront.destroy ~__context ~self:vbd;
	(* It suffices to destroy the datapath: any attached or activated VDIs will be
	   automatically detached and deactivated. *)
	on_vdi ~__context ~vbd ~domid
		(fun rpc task dp sr vdi ->
			let module C = Storage_interface.Client(struct let rpc = rpc end) in
			expect_unit (fun () -> ())
				(C.DP.destroy task dp false)
		)


let diagnostics ~__context =
	expect_string (fun x -> x)
		(Client.DP.diagnostics ())

let dp_destroy ~__context dp allow_leak =
	let task = Context.get_task_id __context in
	expect_unit (fun () -> ())
		(Client.DP.destroy (Ref.string_of task) dp allow_leak)

(* Set my PBD.currently_attached fields in the Pool database to match the local one *)
let resynchronise_pbds ~__context ~pbds =
	let task = Context.get_task_id __context in
	let srs = Client.SR.list (Ref.string_of task) in
	debug "Currently-attached SRs: [ %s ]" (String.concat "; " srs);
	List.iter
		(fun self ->
			let sr = Db.SR.get_uuid ~__context ~self:(Db.PBD.get_SR ~__context ~self) in
			let value = List.mem sr srs in
			debug "Setting PBD %s currently_attached <- %b" (Ref.string_of self) value;
			if value then bind ~__context ~pbd:self;
			Db.PBD.set_currently_attached ~__context ~self ~value
		) pbds

(* -------------------------------------------------------------------------------- *)
(* The following functions are symptoms of a broken interface with the SM layer.
   They should be removed, by enhancing the SM layer. *)

(* This is a layering violation. The layers are:
     xapi: has a pool-wide view
     storage_impl: has a host-wide view of SRs and VDIs
     SM: has a SR-wide viep
   Unfortunately the SM is storing some of its critical state (VDI-host locks) in the xapi
   metadata rather than on the backend storage. The xapi metadata is generally not authoritative
   and must be synchronised against the state of the world. Therefore we must synchronise the
   xapi view with the storage_impl view here. *)
let refresh_local_vdi_activations ~__context =
	let all_vdi_recs = Db.VDI.get_all_records ~__context in
	let localhost = Helpers.get_localhost ~__context in
	let all_hosts = Db.Host.get_all ~__context in

	let key host = Printf.sprintf "host_%s" (Ref.string_of host) in
	let hosts_of vdi_t =
		let prefix = "host_" in
		let ks = List.map fst vdi_t.API.vDI_sm_config in
		let ks = List.filter (String.startswith prefix) ks in
		let ks = List.map (fun k -> String.sub k (String.length prefix) (String.length k - (String.length prefix))) ks in
		List.map Ref.of_string ks in

	(* If this VDI is currently locked to this host, remove the lock.
	   If this VDI is currently locked to a non-existent host (note host references
	   change across pool join), remove the lock. *)
	let unlock_vdi (vdi_ref, vdi_rec) = 
		(* VDI is already unlocked is the common case: avoid eggregious logspam *)
		let hosts = hosts_of vdi_rec in
		let i_locked_it = List.mem localhost hosts in
		let all = List.fold_left (&&) true in
		let someone_leaked_it = all (List.map (fun h -> not(List.mem h hosts)) all_hosts) in
		if i_locked_it || someone_leaked_it then begin
			info "Unlocking VDI %s (because %s)" (Ref.string_of vdi_ref)
				(if i_locked_it then "I locked it and then restarted" else "it was leaked (pool join?)");
			try
				List.iter (fun h -> Db.VDI.remove_from_sm_config ~__context ~self:vdi_ref ~key:(key h)) hosts
			with e ->
				error "Failed to unlock VDI %s: %s" (Ref.string_of vdi_ref) (ExnHelper.string_of_exn e)
		end in
	let open Vdi_automaton in
	(* Lock this VDI to this host *)
	let lock_vdi (vdi_ref, vdi_rec) ro_rw = 
		info "Locking VDI %s" (Ref.string_of vdi_ref);
		if not(List.mem_assoc (key localhost) vdi_rec.API.vDI_sm_config) then begin
			try
				Db.VDI.add_to_sm_config ~__context ~self:vdi_ref ~key:(key localhost) ~value:(string_of_ro_rw ro_rw)
			with e ->
				error "Failed to lock VDI %s: %s" (Ref.string_of vdi_ref) (ExnHelper.string_of_exn e)
		end in
	let remember key ro_rw = 
		(* The module above contains a hashtable of R/O vs R/W-ness *)
		Mutex.execute Builtin_impl.VDI.vdi_read_write_m
			(fun () -> Hashtbl.replace Builtin_impl.VDI.vdi_read_write key (ro_rw = RW)) in

	let task = Ref.string_of (Context.get_task_id __context) in
	let srs = Client.SR.list task in
	List.iter 
		(fun (vdi_ref, vdi_rec) ->
			let sr = Db.SR.get_uuid ~__context ~self:vdi_rec.API.vDI_SR in
			let vdi = vdi_rec.API.vDI_location in
			if List.mem sr srs
			then
				match Client.VDI.stat ~task ~sr ~vdi () with
					| Success (Stat { superstate = Activated RO }) -> 
						lock_vdi (vdi_ref, vdi_rec) RO;
						remember (sr, vdi) RO
					| Success (Stat { superstate = Activated RW }) -> 
						lock_vdi (vdi_ref, vdi_rec) RW;
						remember (sr, vdi) RW
					| Success (Stat { superstate = Attached RO }) -> 
						unlock_vdi (vdi_ref, vdi_rec);
						remember (sr, vdi) RO
					| Success (Stat { superstate = Attached RW }) -> 
						unlock_vdi (vdi_ref, vdi_rec);
						remember (sr, vdi) RW
					| Success (Stat { superstate = Detached }) -> 
						unlock_vdi (vdi_ref, vdi_rec)
					| Success (Params _ | Vdi _ | Vdis _ | String _ | Unit)
					| Failure _ as r -> error "Unable to query state of VDI: %s, %s" vdi (string_of_result r)
			else unlock_vdi (vdi_ref, vdi_rec)
		) all_vdi_recs

(* This is a symptom of the ordering-sensitivity of the SM backend: it is not possible
   to upgrade RO -> RW or downgrade RW -> RO on the fly.
   One possible fix is to always attach RW and enforce read/only-ness at the VBD-level.
   However we would need to fix the LVHD "attach provisioning mode". *)
let vbd_attach_order ~__context vbds = 
	(* return RW devices first since the storage layer can't upgrade a
	   'RO attach' into a 'RW attach' *)
	let rw, ro = List.partition (fun self -> Db.VBD.get_mode ~__context ~self = `RW) vbds in
	rw @ ro

let vbd_detach_order ~__context vbds = List.rev (vbd_attach_order ~__context vbds)

(* This is because the current backends want SR.attached <=> PBD.currently_attached=true.
   It would be better not to plug in the PBD, so that other API calls will be blocked. *)
let destroy_sr ~__context ~sr =
	let pbd, pbd_t = Sm.get_my_pbd_for_sr __context sr in
	bind ~__context ~pbd;
	let task = Ref.string_of (Context.get_task_id __context) in
	expect_unit (fun () -> ())
		(Client.SR.attach task (Db.SR.get_uuid ~__context ~self:sr) pbd_t.API.pBD_device_config);
	(* The current backends expect the PBD to be temporarily set to currently_attached = true *)
	Db.PBD.set_currently_attached ~__context ~self:pbd ~value:true;
	expect_unit (fun () -> ())
		(Client.SR.destroy task (Db.SR.get_uuid ~__context ~self:sr));	
	(* All PBDs are clearly currently_attached = false now *)
	Db.PBD.set_currently_attached ~__context ~self:pbd ~value:false;
	unbind ~__context ~pbd
