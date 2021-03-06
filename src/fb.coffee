try
    {Robot,Adapter,TextMessage,User} = require 'hubot'
catch
    prequire = require('parent-require')
    {Robot,Adapter,TextMessage,User} = prequire 'hubot'
    
Mime = require 'mime'
inspect = require('util').inspect

class FBMessenger extends Adapter

    constructor: ->
        super
        
        @token      = process.env['FB_PAGE_TOKEN']
        @vtoken     = process.env['FB_VERIFY_TOKEN']
        
        @routeURL   = process.env['FB_ROUTE_URL'] or '/hubot/'
            
        _sendImages = process.env['FB_SEND_IMAGES']
        if _sendImages is undefined
            @sendImages = true
        else
            @sendImages = _sendImages is 'true'
        
        @apiURL = 'https://graph.facebook.com/v2.6'
        @messageEndpoint = @apiURL + '/me/messages'
        @subscriptionEndpoint = @apiURL + '/me/subscribed_apps'
        @userProfileEndpoint = @apiURL + '/me/subscribed_apps'
        
        
        @msg_maxlength = 320
        
    send: (envelope, strings...) ->        
        @_sendText envelope.user.id, msg for msg in strings
        if envelope.fb?.richMsg?
            @_sendRich envelope.user.id, envelope.fb.richMsg
            
    _sendText: (user, msg) ->
        data = {
            recipient: {id: user},
            message: {}
        }
        
        if @sendImages
            mime = Mime.lookup(msg)

            if mime is "image/jpeg" or mime is "image/png" or mime is "image/gif"
                data.message.attachment = { type: "image", payload: { url: msg }}
            else
                data.message.text = msg.substring(0,@msg_maxlength)
        else
            data.message.text = msg
        
        @_sendAPI data
        
    _sendRich: (user, richMsg) ->
        data = {
            recipient: {id: user},
            message: richMsg
        }
        @_sendAPI data
        
    _sendAPI: (data) ->
        self = @
        
        data = JSON.stringify(data)
        
        @robot.http(@messageEndpoint)
            .query({access_token:self.token})
            .header('Content-Type', 'application/json')
            .post(data) (error, response, body) ->
                if error
                    self.robot.logger.error 'Error sending message: #{error}'
                    return
                unless response.statusCode in [200, 201]
                    self.robot.logger.error "Send request returned status " +
                    "#{response.statusCode}. data='#{data}'"
                    self.robot.logger.error body
                    return
                        
    reply: (envelope, strings...) ->
        @send envelope, strings
        
    _receiveAPI: (event) ->
        self = @
    
        user = @robot.brain.data.users[event.sender.id]
        unless user?
            self.robot.logger.debug "User doesn't exist, creating"
            @_getUser event.sender.id, event.recipient.id, (user) ->
                self._dispatch event, user
        else
            self.robot.logger.debug "User exists"
            self._dispatch event, user
            
    _dispatch: (event, user) ->
        envelope = {
            event: event,
            user: user,
            room: event.recipient.id
        }        
        
        if event.message?
            @_processMessage event, envelope
        else if event.postback?
            @_processPostback event, envelope
        else if event.delivery?
            @_processDelivery event, envelope
            
    _processMessage: (event, envelope) ->
        @robot.logger.debug inspect event.message
        if event.message.attachments?
            envelope.attachments = event.message.attachments
            @robot.emit "fb_richMsg", envelope
            @_processAttachment event, envelope, attachment for attachment in envelope.attachments
        if event.message.text?
            @receive new TextMessage envelope.user, event.message.text
            
    _processAttachment: (event, envelope, attachment) ->
        unique_envelope = {
            event: event,
            user: envelope.user,
            room: envelope.room,
            attachment: attachment
        }
        @robot.emit "fb_richMsg_#{attachment.type}", unique_envelope
            
    _processPostback: (event, envelope) ->
        envelope.payload = event.postback.payload
        @robot.emit "fb_postback", envelope
        
    _processDelivery: (event, envelope) ->
        @robot.emit "fb_delivery", envelope
        
    _getUser: (userId, page, callback) ->
        self = @
        
        @robot.http(@apiURL + '/' + userId)
            .query({fields:"first_name,last_name,profile_pic",access_token:self.token})
            .get() (error, response, body) ->
                if error
                    self.robot.logger.error 'Error getting user profile: #{error}'
                    return
                unless response.statusCode is 200
                    self.robot.logger.error "Get user profile request returned status " +
                    "#{response.statusCode}. data='#{data}'"
                    self.robot.logger.error body
                    return
                userData = JSON.parse body
                
                userData.name = userData.first_name
                userData.room = page
                
                user = new User userId, userData
                self.robot.brain.data.users[userId] = user
                
                callback user
                
    
    run: ->
        self = @
        
        unless @token
            @emit 'error', new Error 'The environment variable "FB_PAGE_TOKEN" is required.'
            
        unless @vtoken
            @emit 'error', new Error 'The environment variable "FB_VERIFY_TOKEN" is required.'
            
        @robot.http(@subscriptionEndpoint)
            .query({access_token:self.token})
            .post() (error, response, body) -> 
                self.robot.logger.info response + " " + body
        
        @robot.router.get [@routeURL], (req, res) ->
            if req.param('hub.mode') == 'subscribe' and req.param('hub.verify_token') == self.vtoken
                res.send req.param('hub.challenge')
            else
                res.send 400
                
        @robot.router.post [@routeURL], (req, res) ->
            messaging_events = req.body.entry[0].messaging
            self._receiveAPI event for event in messaging_events
            res.send 200
        
        @robot.logger.info "FB-adapter initialized"
        @emit "connected"


exports.use = (robot) ->
    new FBMessenger robot
