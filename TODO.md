//
//  TODO.md
//  darkmatter-ios
//
//  Created by Jeff Gardner on 21/05/26.
//

- [x] On the chat list screen we need to make the subtitle under the chat name be a preview of the latest message in the chat, not the relays and admin status.
- [x] We should remove the chevron at the right of each chat on the chat list screen and put the relative date/timestamp of the last message in that group. e.g. "A few seconds ago, "4m", "2h", "Monday 12:56", "18 May 2026"  
- [x] on the chat list screen for a group of 2 people and there is no name set for the group, it should show the name of the other member, if it's a group with a name, we should show the name instead
- [x] We should remove the tabbar at the bottom of hte screen and make settings accessible from the avatar icon at the top left. that should allow you to switch quickly between accounts or tap a settings link.
- [x] on the chat screen the title of the page should be group name, other user display name (if it's a group of 2), and finally fallback to group id like we have if we cant get anything else.
- [x] On the group info/details screen, we need:
    - [x] A way to update/set the group name
    - [x] Roster should change to Members
    - [x] we need to a way to make another member an admin or remove their admin state.
    - [x] if we're an admin we jneed to be able to remove members too.
    - [x] leave group is slightly more complex - we can't do that if we're the last admin so we need to know that and disable the button with a message.
    - [x] we need a way to archive groups (which flags them archived and puts them in a separate view on the chat list) but this doesn't change our membership or anything else about the group.
- [x] on the chat screen new messages do not show into the chat in realtime when they're sent. we should optimistically add them to the chat (and show pending send state), once that confims, we should show that the message was published to relays.
- [x] I think we need a developer settings section in settings that allows us to turn on some more debugging options. For one, we need a switch in there that allows for chat debugging and when that's turned on that will would create a a link somewhere on the chat itself or maybe it's in the chat info screen. So you type you tap the chat info screen and then there's a thing for or maybe that chat info screen has just sections with lots more details about the actual MLS group, epoch, number of members, the leaves, you know, anything else that's in there that we can show.
- [x] on the chat screen we need to make the chats from me vs other people from from different sides of the screen. so my messages should show on the right side, and and other people on the left. also - I'm not seeing any timestamps or any other details there about when messagers were sent.
- [ ] on the chat screen we need some sort of contextual menu that like when you hold on a message pops up and shows you a bunch of emojis that you can react with and also an option to reply to messages. I think the reply should be a swipe. You know, so you swipe to the right and that will automatically kind of bounce the message and then starts a reply message and shows the actual message that you're replying to just above the message input field.
- [x] the avatar button at the top left still seems to have padding around it to show the glass effect. can we remove that padding? if so, we should we still want the button's default drop shadow and behavior but the avatar image should bleed all the way to the edges of the button.
- [x] on the chat screen we should remove the grey background from behind the message compose and just let the textfield and the send button float. 
- [x] on the chat screen the max-width of message bubbles should be full width on ios and pretty wide (but maybe not quite full width) on ipad.
