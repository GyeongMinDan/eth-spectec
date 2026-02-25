(** Ethereum Target - Main module exporting all components *)

module Target = Eth_common.Target
module StateTransition = State_transition.StateTransition
module Operations = Operations
module Epoch = Epoch
module Slots = Slots.Slots
module JsonParse = Eth_common.JsonParse
